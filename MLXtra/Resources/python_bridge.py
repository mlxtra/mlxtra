#!/usr/bin/env python3
"""
MLX-VLM Python Bridge for Swift macOS App
Transparent proxy - no custom logic, just forwards to mlx-vlm
Only JSON goes to stdout. Debug output goes to stderr.
"""

import sys
import json
import os
import gc
import math
import re
import signal
import selectors
import subprocess
import time
import uuid
import contextlib
from typing import List, Dict, Optional, Any, Tuple
from pathlib import Path

from bridge_utils import (
    build_acestep_generation_inputs,
    coerce_string,
    log_exception,
    normalize_music_model_id,
)

MODEL_REGISTRY: Dict[str, Any] = {}
DRAFTER_MODEL_REGISTRY: Dict[str, Any] = {}
IMAGE_MODEL_REGISTRY: Dict[str, Any] = {}
AUDIO_MODEL_REGISTRY: Dict[str, Any] = {}
MUSIC_MODEL_REGISTRY: Dict[str, Any] = {}
BRIDGE_PROCESS_STARTED = time.perf_counter()
RUNTIME_MANIFEST_CACHE: Optional[Dict[str, Any]] = None
ESPEAK_RUNTIME_CONFIGURED_FOR: Optional[str] = None


def bridge_debug_enabled() -> bool:
    return os.environ.get("MLXTRA_BRIDGE_DEBUG", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def bridge_timing_enabled() -> bool:
    return os.environ.get("MLXTRA_BRIDGE_TIMING", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def log_debug(msg: str):
    """Log debug message to stderr when explicitly enabled."""
    if not bridge_debug_enabled():
        return
    print(msg, file=sys.stderr, flush=True)


def _positive_finite_float(value: Any) -> Optional[float]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) and number > 0 else None


TOKEN_BATCH_SIZE = 10
TOKEN_BATCH_FLUSH_S = 0.030


def _chat_performance_payload(
    *,
    prompt_tps: Any = None,
    generation_tps: Any = None,
    peak_memory_gb: Any = None,
    completion_tokens: int = 0,
) -> Dict[str, float]:
    metrics: Dict[str, float] = {}

    prompt_tokens_per_second = _positive_finite_float(prompt_tps)
    if prompt_tokens_per_second is not None:
        metrics["prompt_tokens_per_second"] = prompt_tokens_per_second

    generation_tokens_per_second = _positive_finite_float(generation_tps)
    if generation_tokens_per_second is not None:
        metrics["generation_tokens_per_second"] = generation_tokens_per_second
        metrics["tokens_per_second"] = generation_tokens_per_second
        if completion_tokens > 0:
            metrics["generation_duration"] = completion_tokens / generation_tokens_per_second

    peak_memory = _positive_finite_float(peak_memory_gb)
    if peak_memory is not None:
        metrics["peak_memory_gb"] = peak_memory

    return metrics


def get_request_id(request: Optional[dict] = None) -> Optional[str]:
    if not isinstance(request, dict):
        return None

    request_id = request.get("request_id")
    if request_id is None:
        return None

    return str(request_id)


def send_json(
    obj: dict,
    *,
    request: Optional[dict] = None,
    request_id: Optional[str] = None,
):
    """Send JSON object to stdout (only valid JSON goes to stdout)"""
    payload = dict(obj)
    inherited_request_id = request_id if request_id is not None else get_request_id(request)
    if inherited_request_id:
        payload.setdefault("request_id", inherited_request_id)
    print(json.dumps(payload), flush=True)


def send_model_loading(
    model_id: str,
    phase: str,
    *,
    backend: str,
    request: Optional[dict] = None,
    detail: Optional[str] = None,
):
    payload = {
        "type": "model.loading",
        "model": model_id,
        "backend": backend,
        "status": phase,
        "phase": phase,
    }
    if detail:
        payload["detail"] = detail
    send_json(payload, request=request)


def send_timing(
    name: str,
    started_at: float,
    *,
    request: Optional[dict] = None,
    detail: Optional[str] = None,
    **extra: Any,
):
    if not bridge_timing_enabled():
        return

    now = time.perf_counter()
    payload: Dict[str, Any] = {
        "type": "trace.timing",
        "name": name,
        "duration_ms": round((now - started_at) * 1000, 3),
        "since_process_start_ms": round((now - BRIDGE_PROCESS_STARTED) * 1000, 3),
    }
    if detail:
        payload["detail"] = detail
    for key, value in extra.items():
        if value is not None:
            payload[key] = value
    send_json(payload, request=request)


def _runtime_python_versions() -> List[str]:
    versions = [
        f"python{sys.version_info.major}.{sys.version_info.minor}",
        "python3.13",
        "python3.12",
        "python3.11",
    ]
    return list(dict.fromkeys(versions))


def _runtime_root_from_python(executable: str) -> Optional[Path]:
    if not executable:
        return None

    candidates = [Path(executable)]
    try:
        resolved = Path(executable).resolve()
        if resolved != candidates[0]:
            candidates.append(resolved)
    except OSError:
        pass

    for candidate in candidates:
        if candidate.parent.name == "bin" and candidate.parent.parent.name == "venv":
            runtime_root = candidate.parent.parent.parent
            if (runtime_root / "venv").exists():
                return runtime_root
    return None


def _bundled_runtime_root() -> Path:
    return Path(__file__).resolve().parent / "runtime" / "macos-arm64"


def _add_runtime_root_candidate(
    candidates: List[Path], seen: set[str], runtime_root: Optional[Path]
) -> None:
    if runtime_root is None:
        return

    try:
        normalized = runtime_root.expanduser().resolve()
    except OSError:
        normalized = runtime_root.expanduser()

    if not (normalized / "venv").exists():
        return

    key = str(normalized)
    if key not in seen:
        candidates.append(normalized)
        seen.add(key)


def _runtime_root_candidates() -> List[Path]:
    candidates: List[Path] = []
    seen: set[str] = set()

    runtime_override = os.environ.get("MLXTRA_RUNTIME_DIR")
    if runtime_override:
        _add_runtime_root_candidate(candidates, seen, Path(runtime_override))

    _add_runtime_root_candidate(
        candidates, seen, _runtime_root_from_python(sys.executable)
    )
    _add_runtime_root_candidate(candidates, seen, _bundled_runtime_root())

    return candidates


def _site_packages_for_runtime(runtime_root: Path) -> Optional[Path]:
    venv_path = runtime_root / "venv"
    for py_version in _runtime_python_versions():
        site_packages = venv_path / "lib" / py_version / "site-packages"
        if site_packages.exists():
            return site_packages
    return None


def _runtime_site_packages_candidates() -> List[Path]:
    paths: List[Path] = []
    seen: set[str] = set()
    for runtime_root in _runtime_root_candidates():
        site_packages = _site_packages_for_runtime(runtime_root)
        if site_packages is None:
            continue
        key = str(site_packages)
        if key not in seen:
            paths.append(site_packages)
            seen.add(key)
    return paths


def setup_environment():
    """Setup Python environment for the active app runtime."""
    started_at = time.perf_counter()
    site_packages_paths = _runtime_site_packages_candidates()

    for site_packages in reversed(site_packages_paths):
        site_packages_path = str(site_packages)
        sys.path[:] = [path for path in sys.path if path != site_packages_path]
        sys.path.insert(0, site_packages_path)

    _configure_espeak_runtime()
    send_timing("bridge.setup_environment", started_at)


def _configure_espeak_runtime() -> Optional[Path]:
    """Point phonemizer/espeak at the active runtime's bundled data files."""
    global ESPEAK_RUNTIME_CONFIGURED_FOR

    for site_packages in _runtime_site_packages_candidates():
        loader_dir = site_packages / "espeakng_loader"
        library_path = loader_dir / "libespeak-ng.dylib"
        data_path = loader_dir / "espeak-ng-data"
        if not (
            library_path.exists()
            and data_path.is_dir()
            and (data_path / "phontab").exists()
        ):
            continue

        configured_for = str(loader_dir)
        os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = str(library_path)
        os.environ["PHONEMIZER_ESPEAK_DATA_PATH"] = str(data_path)

        wrapper_module = sys.modules.get("phonemizer.backend.espeak.wrapper")
        wrapper = getattr(wrapper_module, "EspeakWrapper", None)
        if wrapper is not None:
            try:
                wrapper.set_library(str(library_path))
                wrapper.set_data_path(str(data_path))
            except Exception:
                pass

        ESPEAK_RUNTIME_CONFIGURED_FOR = configured_for
        return loader_dir

    ESPEAK_RUNTIME_CONFIGURED_FOR = None
    return None


def _clear_accelerator_cache():
    mx = sys.modules.get("mlx.core")
    if mx is not None:
        try:
            mx.clear_cache()
        except Exception:
            pass
    gc.collect()


def unload_models(keep_registry: Optional[Dict[str, Any]] = None, keep_key: Optional[str] = None):
    """Drop cached model objects, optionally preserving one active model."""
    removed = False
    for registry in (
        MODEL_REGISTRY,
        DRAFTER_MODEL_REGISTRY,
        IMAGE_MODEL_REGISTRY,
        AUDIO_MODEL_REGISTRY,
        MUSIC_MODEL_REGISTRY,
    ):
        for key in list(registry.keys()):
            if registry is keep_registry and key == keep_key:
                continue
            model_obj = registry.pop(key, None)
            if model_obj is not None:
                del model_obj
                removed = True

    if removed:
        _clear_accelerator_cache()


def load_model_if_needed(model_id: str, request: Optional[dict] = None):
    """Lazy load model, cache in registry"""
    if model_id in MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Model {model_id} already loaded, using cache")
        return MODEL_REGISTRY[model_id]

    total_started_at = time.perf_counter()
    import_started_at = time.perf_counter()
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    send_timing("model.mlx_imports", import_started_at, request=request, model=model_id)

    send_model_loading(
        model_id,
        "loading_weights",
        backend="vlm",
        request=request,
        detail="Loading model weights",
    )

    try:
        unload_started_at = time.perf_counter()
        unload_models()
        send_timing("model.unload_existing", unload_started_at, request=request, model=model_id)

        log_debug(f"[Python Bridge] Loading model: {model_id}")
        weights_started_at = time.perf_counter()
        model, processor = load(model_id)
        send_timing("model.weights", weights_started_at, request=request, model=model_id)

        config_started_at = time.perf_counter()
        config = load_config(model_id)
        send_timing("model.config", config_started_at, request=request, model=model_id)

        MODEL_REGISTRY[model_id] = (model, processor, config)

        send_model_loading(
            model_id,
            "warming",
            backend="vlm",
            request=request,
            detail="Warming model",
        )
        warmup_started_at = time.perf_counter()
        send_timing(
            "model.warmup",
            warmup_started_at,
            request=request,
            model=model_id,
            detail="No explicit warmup work currently runs before model.loaded",
        )
        send_timing("model.load_total", total_started_at, request=request, model=model_id)
        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Model {model_id} loaded successfully")

        return model, processor, config
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load model {model_id}: {str(e)}")
        raise


def _mflux_options_from_request(request: Optional[dict]) -> dict:
    runtime_options = _runtime_options_from_request(request)
    mflux_options = runtime_options.get("mflux")
    return mflux_options if isinstance(mflux_options, dict) else {}


def _acceleration_options_from_request(request: Optional[dict]) -> dict:
    runtime_options = _runtime_options_from_request(request)
    acceleration_options = runtime_options.get("acceleration")
    return acceleration_options if isinstance(acceleration_options, dict) else {}


def _runtime_options_from_request(request: Optional[dict]) -> dict:
    if not isinstance(request, dict):
        return {}

    parameters = request.get("parameters")
    if not isinstance(parameters, dict):
        return {}

    runtime_options = parameters.get("runtimeOptions") or parameters.get("runtime_options")
    if not isinstance(runtime_options, dict):
        return {}

    return runtime_options


def _positive_int(value: Any) -> Optional[int]:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _load_drafter_if_requested(
    model_id: str,
    request: Optional[dict] = None,
) -> Tuple[Optional[Any], Optional[str], Optional[int]]:
    acceleration_options = _acceleration_options_from_request(request)
    draft_model_path = (
        acceleration_options.get("draftModel")
        or acceleration_options.get("draft_model")
        or acceleration_options.get("model")
        or acceleration_options.get("path")
    )
    if not draft_model_path:
        return None, None, None

    draft_model_path = str(draft_model_path)
    draft_kind = acceleration_options.get("draftKind") or acceleration_options.get("draft_kind")
    draft_kind = str(draft_kind) if draft_kind else None
    draft_block_size = (
        _positive_int(acceleration_options.get("draftBlockSize"))
        or _positive_int(acceleration_options.get("draft_block_size"))
    )
    cache_key = f"{draft_model_path}:{draft_kind or 'auto'}"

    if cache_key in DRAFTER_MODEL_REGISTRY:
        draft_model, resolved_kind = DRAFTER_MODEL_REGISTRY[cache_key]
        return draft_model, resolved_kind, draft_block_size

    try:
        from mlx_vlm.speculative.drafters import load_drafter

        send_model_loading(
            model_id,
            "loading_acceleration",
            backend="vlm",
            request=request,
            detail="Loading acceleration files",
        )
        draft_model, resolved_kind = load_drafter(draft_model_path, kind=draft_kind)
        DRAFTER_MODEL_REGISTRY[cache_key] = (draft_model, resolved_kind)
        send_model_loading(
            model_id,
            "acceleration_ready",
            backend="vlm",
            request=request,
            detail="Acceleration ready",
        )
        return draft_model, resolved_kind, draft_block_size
    except Exception as exc:
        log_debug(f"[Python Bridge] Acceleration unavailable for {model_id}: {exc}")
        send_model_loading(
            model_id,
            "acceleration_unavailable",
            backend="vlm",
            request=request,
            detail="Acceleration unavailable; continuing without it",
        )
        return None, None, None


def _audio_options_from_request(request: Optional[dict]) -> dict:
    runtime_options = _runtime_options_from_request(request)
    audio_options = runtime_options.get("audio")
    return audio_options if isinstance(audio_options, dict) else {}


def _runtime_manifest() -> Dict[str, Any]:
    global RUNTIME_MANIFEST_CACHE
    if RUNTIME_MANIFEST_CACHE is not None:
        return RUNTIME_MANIFEST_CACHE

    manifest = {}
    for runtime_root in _runtime_root_candidates():
        manifest_path = runtime_root / "runtime-manifest.json"
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                manifest = json.load(handle)
            break
        except FileNotFoundError:
            continue
        except Exception as exc:
            raise RuntimeError(f"Could not read runtime manifest: {exc}") from exc

    RUNTIME_MANIFEST_CACHE = manifest if isinstance(manifest, dict) else {}
    return RUNTIME_MANIFEST_CACHE


def _runtime_mflux_capabilities() -> dict:
    image_runtimes = _runtime_manifest().get("imageRuntimes", {})
    if not isinstance(image_runtimes, dict):
        return {}
    mflux = image_runtimes.get("mflux", {})
    return mflux if isinstance(mflux, dict) else {}


def _safe_filename_component(value: str) -> str:
    component = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-._").lower()
    return component[:80] or "image"


def _audio_adapter(request: Optional[dict]) -> str:
    adapter = str(_audio_options_from_request(request).get("adapter") or "generic").strip()
    return adapter or "generic"


def _audio_default_voice(request: Optional[dict]) -> str:
    default_voice = str(_audio_options_from_request(request).get("defaultVoice") or "default").strip()
    return default_voice or "default"


def _lang_code_for_voice(request: Optional[dict], voice: str) -> str:
    language_by_prefix = _audio_options_from_request(request).get("languageByVoicePrefix", {})
    if not isinstance(language_by_prefix, dict):
        language_by_prefix = {}
    prefix = voice.lower().split("_", 1)[0]
    return str(language_by_prefix.get(prefix) or "a").strip() or "a"


def _coerce_float_parameter(value: Any, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _coerce_int_parameter(value: Any, default: int) -> int:
    try:
        number = int(float(value))
    except (TypeError, ValueError):
        return default
    return number


def _coerce_positive_int_parameter(value: Any, default: int) -> int:
    number = _coerce_int_parameter(value, default)
    return number if number > 0 else default


def _first_present_parameter(*values: Any, default: Any = None) -> Any:
    for value in values:
        if value is None:
            continue
        if isinstance(value, str) and value == "":
            continue
        return value
    return default


def _mflux_class_by_name(class_name: str):
    if class_name in {"Flux2Klein", "Flux2KleinEdit"}:
        from mflux.models.flux2.variants import Flux2Klein, Flux2KleinEdit

        return {
            "Flux2Klein": Flux2Klein,
            "Flux2KleinEdit": Flux2KleinEdit,
        }[class_name]

    if class_name in {"ZImage", "ZImageTurbo"}:
        from mflux.models.z_image import ZImage, ZImageTurbo

        return {
            "ZImage": ZImage,
            "ZImageTurbo": ZImageTurbo,
        }[class_name]

    raise ValueError(f"Unsupported mflux model class '{class_name}'")


def _resolve_mflux_model(model_id: str, edit: bool, request: Optional[dict] = None):
    options = _mflux_options_from_request(request)
    configured_name = str(options.get("config") or "").strip()
    if not configured_name:
        raise ValueError("Missing required runtimeOptions.mflux.config for image model")
    capabilities = _runtime_mflux_capabilities()
    allowed_configs = set(capabilities.get("configs") or [])
    if allowed_configs and configured_name not in allowed_configs:
        allowed = ", ".join(sorted(allowed_configs))
        raise ValueError(
            f"Unsupported mflux model config '{configured_name}'. Allowed configs: {allowed}"
        )

    from mflux.models.common.config import ModelConfig

    model_config = ModelConfig.from_name(model_name=configured_name)

    class_key = "editClass" if edit else "textToImageClass"
    class_name = str(options.get(class_key) or "").strip()
    if not class_name:
        raise ValueError(f"Missing required runtimeOptions.mflux.{class_key} for image model")
    allowed_classes = set(capabilities.get("classes") or [])
    if allowed_classes and class_name not in allowed_classes:
        allowed = ", ".join(sorted(allowed_classes))
        raise ValueError(
            f"Unsupported mflux model class '{class_name}'. Allowed classes: {allowed}"
        )

    quantize = options.get("quantize")
    if quantize is not None:
        try:
            quantize = int(quantize)
        except (TypeError, ValueError):
            raise ValueError(f"Unsupported mflux quantize value '{quantize}'")
        allowed_quantize = set(capabilities.get("quantizeBits") or [])
        if allowed_quantize and quantize not in allowed_quantize:
            allowed = ", ".join(str(bits) for bits in sorted(allowed_quantize))
            raise ValueError(
                f"Unsupported mflux quantize value '{quantize}'. Allowed values: {allowed}"
            )

    return _mflux_class_by_name(class_name), model_config, quantize


def load_image_model_if_needed(
    model_id: str, edit: bool = False, request: Optional[dict] = None
):
    """Lazy load mflux image model, cache in registry"""
    model_class, model_config, quantize = _resolve_mflux_model(model_id, edit, request)
    configured_name = getattr(model_config, "model_name", "") or str(
        _mflux_options_from_request(request).get("config") or model_id
    )
    model_class_name = getattr(model_class, "__name__", model_class.__class__.__name__)
    cache_key = f"{model_id}:{configured_name}:{model_class_name}:q{quantize or 'none'}"
    if cache_key in IMAGE_MODEL_REGISTRY:
        log_debug(
            f"[Python Bridge] Image model {cache_key} already loaded, using cache"
        )
        return IMAGE_MODEL_REGISTRY[cache_key]

    send_model_loading(
        model_id,
        "loading_weights",
        backend="image",
        request=request,
        detail="Loading image model",
    )

    try:
        unload_models()
        log_debug(f"[Python Bridge] Loading image model: {model_id}")

        model = model_class(model_path=model_id, model_config=model_config, quantize=quantize)

        IMAGE_MODEL_REGISTRY[cache_key] = model

        send_model_loading(
            model_id,
            "warming",
            backend="image",
            request=request,
            detail="Warming image model",
        )
        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Image model {model_id} loaded successfully")

        return model
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load image model {model_id}: {str(e)}")
        raise


def load_audio_model_if_needed(model_id: str, request: Optional[dict] = None):
    """Lazy load mlx-audio TTS model, cache in registry"""
    if model_id in AUDIO_MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Audio model {model_id} already loaded, using cache")
        return AUDIO_MODEL_REGISTRY[model_id]

    send_model_loading(
        model_id,
        "loading_weights",
        backend="audio",
        request=request,
        detail="Loading speech model",
    )

    try:
        unload_models()
        _configure_espeak_runtime()
        log_debug(f"[Python Bridge] Loading audio model: {model_id}")
        from mlx_audio.tts.utils import load_model

        model = load_model(model_id)
        AUDIO_MODEL_REGISTRY[model_id] = model

        send_model_loading(
            model_id,
            "warming",
            backend="audio",
            request=request,
            detail="Warming speech model",
        )
        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Audio model {model_id} loaded successfully")

        return model
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load audio model {model_id}: {str(e)}")
        raise


def load_music_model_if_needed(model_id: str, request: Optional[dict] = None):
    """Lazy load ACE-Step music generation handlers."""
    normalized_id = normalize_music_model_id(model_id)

    if model_id in MUSIC_MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Music model {model_id} already loaded, using cache")
        unload_models(keep_registry=MUSIC_MODEL_REGISTRY, keep_key=model_id)
        return MUSIC_MODEL_REGISTRY[model_id]

    send_model_loading(
        model_id,
        "loading_weights",
        backend="music",
        request=request,
        detail="Loading music model",
    )

    try:
        unload_models()
        log_debug(
            f"[Python Bridge] Loading music model: {model_id} (normalized: {normalized_id})"
        )
        import importlib.util

        with contextlib.redirect_stdout(sys.stderr):
            from acestep.handler import AceStepHandler
            from acestep.llm_inference import LLMHandler

        package_spec = importlib.util.find_spec("acestep")
        project_root = (
            Path(package_spec.origin).parent.parent
            if package_spec and package_spec.origin
            else Path.cwd()
        )

        config_path = os.environ.get("ACESTEP_CONFIG_PATH") or normalized_id

        with contextlib.redirect_stdout(sys.stderr):
            dit_handler = AceStepHandler()
            init_result = dit_handler.initialize_service(
                project_root=str(project_root),
                config_path=str(config_path),
                device=os.environ.get("ACESTEP_DEVICE", "mps"),
            )
        if not init_result or init_result[1] is False:
            error_msg = (
                init_result[0] if init_result else "Unknown initialization error"
            )
            raise RuntimeError(f"Failed to initialize ACE-Step model: {error_msg}")

        with contextlib.redirect_stdout(sys.stderr):
            llm_handler = LLMHandler()
        MUSIC_MODEL_REGISTRY[model_id] = (dit_handler, llm_handler)

        send_model_loading(
            model_id,
            "warming",
            backend="music",
            request=request,
            detail="Warming music model",
        )
        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Music model {model_id} loaded successfully")

        return dit_handler, llm_handler
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load music model {model_id}: {str(e)}")
        raise


def _normalize_messages(messages: list) -> list:
    """Normalize OpenAI-style messages for stricter chat templates.

    Some templates (e.g. Qwen3.5) call |items on arguments, which only
    works on mappings. The OpenAI spec allows arguments as a JSON string,
    so we convert it here.

    Qwen templates also require system instructions to be a single leading
    message. Merge any later system messages into that leading message.
    """
    normalized = []
    system_contents = []
    for msg in messages:
        msg = dict(msg)
        if msg.get("role") == "system":
            content = msg.get("content")
            if content:
                system_contents.append(str(content))
            continue
        if "tool_calls" in msg and isinstance(msg["tool_calls"], list):
            tc_list = []
            for tc in msg["tool_calls"]:
                tc = dict(tc)
                if "function" in tc and isinstance(tc["function"], dict):
                    fn = dict(tc["function"])
                    if "arguments" in fn and isinstance(fn["arguments"], str):
                        try:
                            fn["arguments"] = json.loads(fn["arguments"])
                        except (json.JSONDecodeError, ValueError):
                            pass
                    tc["function"] = fn
                tc_list.append(tc)
            msg["tool_calls"] = tc_list
        normalized.append(msg)
    if system_contents:
        normalized.insert(
            0,
            {
                "role": "system",
                "content": "\n\n".join(system_contents),
            },
        )
    return normalized


def parse_tool_calls(text: str) -> List[Dict[str, Any]]:
    """Parse tool calls from model output. Tries common template formats."""
    tool_calls = []

    def coerce_parameter_value(value: str) -> Any:
        stripped = value.strip()
        lowered = stripped.lower()
        if lowered == "true":
            return True
        if lowered == "false":
            return False
        try:
            if re.fullmatch(r"[-+]?\d+", stripped):
                return int(stripped)
            if re.fullmatch(r"[-+]?(?:\d+\.\d*|\.\d+)(?:[eE][-+]?\d+)?|[-+]?\d+[eE][-+]?\d+", stripped):
                return float(stripped)
        except ValueError:
            pass
        return stripped

    def append_tool_call(fn_name: Any, args: Any) -> None:
        if not isinstance(fn_name, str) or not fn_name.strip():
            return
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except (json.JSONDecodeError, ValueError):
                args = {}
        if not isinstance(args, dict):
            args = {}
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {"name": fn_name.strip(), "arguments": json.dumps(args)},
            }
        )

    def append_json_tool_call(value: Any) -> None:
        if not isinstance(value, dict):
            return

        function = value.get("function")
        if isinstance(function, dict):
            append_tool_call(
                function.get("name"),
                function.get("arguments", value.get("parameters", {})),
            )
            return

        append_tool_call(
            value.get("name"),
            value.get("parameters", value.get("arguments", {})),
        )

    def parse_json_tool_calls() -> None:
        stripped = text.strip()
        fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", stripped, re.DOTALL | re.IGNORECASE)
        if fenced:
            stripped = fenced.group(1).strip()
        if not stripped.startswith(("{", "[")):
            return

        try:
            value = json.loads(stripped)
        except (json.JSONDecodeError, ValueError):
            return

        if isinstance(value, dict) and isinstance(value.get("tool_calls"), list):
            candidates = value["tool_calls"]
        elif isinstance(value, list):
            candidates = value
        else:
            candidates = [value]

        for candidate in candidates:
            append_json_tool_call(candidate)

    # Qwen3.5 format: <function=name>\n<parameter=key>\nvalue\n</parameter>\n</function>
    fn_pattern = re.compile(r"<function=([^>]+)>(.*?)</function>", re.DOTALL)
    for m in fn_pattern.finditer(text):
        fn_name = m.group(1).strip()
        fn_body = m.group(2)
        args = {}
        param_pattern = re.compile(r"<parameter=([^>]+)>(.*?)</parameter>", re.DOTALL)
        for p in param_pattern.finditer(fn_body):
            args[p.group(1).strip()] = coerce_parameter_value(p.group(2))
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {"name": fn_name, "arguments": json.dumps(args)},
            }
        )

    if tool_calls:
        return tool_calls

    # Plain JSON formats are common when small models follow generic tool instructions:
    # {"name": "web_search", "parameters": {"query": "..."}}
    # {"tool_calls": [{"function": {"name": "web_search", "arguments": "{\"query\":\"...\"}"}}]}
    parse_json_tool_calls()
    if tool_calls:
        return tool_calls

    # Gemma 4 format:
    # <|tool_call|>call:name(param: "value")<|tool_call|>
    # Some variants omit one pipe and use braces:
    # <|tool_call>call:name{param:<|"|>value<|"|>}<tool_call|>
    gemma_pattern = re.compile(
        r"<\|?tool_call\|?>\s*call:([^\s({]+)\s*([({])(.*?)([)}])\s*<\|?tool_call\|?>",
        re.DOTALL,
    )
    for m in gemma_pattern.finditer(text):
        fn_name = m.group(1).strip()
        open_delimiter = m.group(2)
        close_delimiter = m.group(4)
        if (open_delimiter == "(" and close_delimiter != ")") or (
            open_delimiter == "{" and close_delimiter != "}"
        ):
            continue
        args_str = m.group(3).replace('<|"|>', '"').strip()
        args = {}
        arg_pattern = re.compile(
            r'(\w+):\s*(?:"((?:\\.|[^"\\])*)"|([^,)}]*?))(?=,|\s*$)',
            re.DOTALL,
        )
        for pair in arg_pattern.finditer(args_str):
            key = pair.group(1)
            quoted_value = pair.group(2)
            raw_value = pair.group(3)
            if quoted_value is not None:
                try:
                    args[key] = json.loads(f'"{quoted_value}"')
                except json.JSONDecodeError:
                    args[key] = quoted_value
            elif raw_value is not None:
                args[key] = coerce_parameter_value(raw_value)
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {"name": fn_name, "arguments": json.dumps(args)},
            }
        )

    return tool_calls


def handle_chat_completion(request: dict) -> None:
    """Handle chat.completions request - transparent proxy to mlx-vlm"""
    request_started_at = time.perf_counter()
    imports_started_at = time.perf_counter()

    _mono = time.monotonic
    _last_flush = _mono()
    token_buffer: str = ""

    model_id = request["model"]
    messages = request["messages"]
    max_tokens = request.get("max_tokens", 32768)
    temperature = request.get("temperature", 0.7)
    top_p = request.get("top_p", 1.0)
    top_k = request.get("top_k", 0)
    min_p = request.get("min_p", 0.0)
    repetition_penalty = request.get("repetition_penalty")
    images = request.get("images", [])
    tools = request.get("tools")

    chat_template_kwargs = request.get("chat_template_kwargs", {})

    try:
        from mlx_vlm import stream_generate
        from mlx_vlm.prompt_utils import apply_chat_template
        send_timing("chat.imports", imports_started_at, request=request)

        model_was_cached = model_id in MODEL_REGISTRY
        model_ready_started_at = time.perf_counter()
        model, processor, config = load_model_if_needed(model_id, request=request)
        send_timing(
            "chat.model_ready",
            model_ready_started_at,
            request=request,
            model=model_id,
            cached=model_was_cached,
        )
        normalized_messages = _normalize_messages(messages)

        template_started_at = time.perf_counter()
        if tools:
            prompt = processor.apply_chat_template(
                normalized_messages,
                tools=tools,
                add_generation_prompt=True,
                tokenize=False,
                **chat_template_kwargs,
            )
        else:
            prompt = apply_chat_template(
                processor,
                config,
                normalized_messages,
                num_images=len(images),
                **chat_template_kwargs,
            )
        send_timing("chat.prompt_template", template_started_at, request=request, model=model_id)

        log_debug(f"[Python Bridge] Prompt: {prompt[:200]}...")

        full_response = ""
        prompt_tokens = 0
        completion_tokens = 0
        prompt_tps = None
        generation_tps = None
        peak_memory_gb = None

        acceleration_options = _acceleration_options_from_request(request)
        acceleration_requested = bool(
            acceleration_options.get("draftModel")
            or acceleration_options.get("draft_model")
            or acceleration_options.get("model")
            or acceleration_options.get("path")
        )
        acceleration_state = None

        draft_model, draft_kind, draft_block_size = _load_drafter_if_requested(
            model_id,
            request=request,
        )
        if acceleration_requested:
            acceleration_state = "active" if draft_model is not None else "unavailable"
        generation_kwargs = {
            "max_tokens": max_tokens,
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k,
            "min_p": min_p,
            "repetition_penalty": repetition_penalty,
            "verbose": False,
        }
        if draft_model is not None:
            generation_kwargs["draft_model"] = draft_model
            if draft_kind:
                generation_kwargs["draft_kind"] = draft_kind
            if draft_block_size:
                generation_kwargs["draft_block_size"] = draft_block_size

        generation_started_at = time.perf_counter()
        first_token_sent = False

        def consume_generation_stream(active_generation_kwargs: dict) -> None:
            nonlocal token_buffer
            nonlocal full_response
            nonlocal prompt_tokens
            nonlocal completion_tokens
            nonlocal prompt_tps
            nonlocal generation_tps
            nonlocal peak_memory_gb
            nonlocal first_token_sent
            nonlocal _last_flush

            for chunk in stream_generate(
                model,
                processor,
                prompt,
                image=images if images else None,
                **active_generation_kwargs,
            ):
                token = chunk.text
                full_response += token
                token_buffer += token
                prompt_tokens = chunk.prompt_tokens
                completion_tokens = chunk.generation_tokens
                prompt_tps = getattr(chunk, "prompt_tps", prompt_tps)
                generation_tps = getattr(chunk, "generation_tps", generation_tps)
                peak_memory_gb = getattr(chunk, "peak_memory", peak_memory_gb)

                now = _mono()
                if len(token_buffer) >= TOKEN_BATCH_SIZE or (now - _last_flush) >= TOKEN_BATCH_FLUSH_S:
                    if token_buffer:
                        if not first_token_sent:
                            send_timing(
                                "chat.first_token",
                                generation_started_at,
                                request=request,
                                model=model_id,
                                since_chat_request_ms=round(
                                    (time.perf_counter() - request_started_at) * 1000, 3
                                ),
                            )
                            first_token_sent = True
                        send_json(
                            {"type": "chat.completion.chunk",
                             "choices": [{"delta": {"content": token_buffer}}]},
                            request=request,
                        )
                        token_buffer = ""
                        _last_flush = now

        try:
            consume_generation_stream(generation_kwargs)
        except Exception as generation_error:
            if draft_model is None or full_response:
                raise
            log_debug(f"[Python Bridge] Acceleration failed during generation for {model_id}: {generation_error}")
            send_model_loading(
                model_id,
                "acceleration_unavailable",
                backend="vlm",
                request=request,
                detail="Acceleration unavailable; continuing without it",
            )
            generation_kwargs.pop("draft_model", None)
            generation_kwargs.pop("draft_kind", None)
            generation_kwargs.pop("draft_block_size", None)
            DRAFTER_MODEL_REGISTRY.clear()
            _clear_accelerator_cache()
            generation_started_at = time.perf_counter()
            first_token_sent = False
            acceleration_state = "fallback"
            consume_generation_stream(generation_kwargs)

        if token_buffer:
            if not first_token_sent:
                send_timing(
                    "chat.first_token",
                    generation_started_at,
                    request=request,
                    model=model_id,
                    since_chat_request_ms=round(
                        (time.perf_counter() - request_started_at) * 1000, 3
                    ),
                )
                first_token_sent = True
            send_json(
                {"type": "chat.completion.chunk",
                 "choices": [{"delta": {"content": token_buffer}}]},
                request=request,
            )
        send_timing(
            "chat.generation",
            generation_started_at,
            request=request,
            model=model_id,
            completion_tokens=completion_tokens,
        )

        parsed_tool_calls = parse_tool_calls(full_response)

        performance = _chat_performance_payload(
            prompt_tps=prompt_tps,
            generation_tps=generation_tps,
            peak_memory_gb=peak_memory_gb,
            completion_tokens=completion_tokens,
        )
        acceleration_payload = None
        if acceleration_requested:
            acceleration_payload = {
                "requested": True,
                "active": acceleration_state == "active",
                "state": acceleration_state or "unavailable",
            }
            if draft_kind and acceleration_state == "active":
                acceleration_payload["draft_kind"] = draft_kind
        send_timing("chat.request_total", request_started_at, request=request, model=model_id)

        if parsed_tool_calls:
            payload = {
                "type": "chat.completion.tool_calls",
                "tool_calls": parsed_tool_calls,
                "content": full_response,
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                },
            }
            if performance:
                payload["performance"] = performance
            if acceleration_payload:
                payload["acceleration"] = acceleration_payload
            send_json(payload, request=request)
        else:
            payload = {
                "type": "chat.completion.complete",
                "choices": [{"message": {"content": full_response}}],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                },
            }
            if performance:
                payload["performance"] = performance
            if acceleration_payload:
                payload["acceleration"] = acceleration_payload
            send_json(payload, request=request)

    except Exception as e:
        error_msg = log_exception("[Python Bridge] Error", e, logger=log_debug)
        send_json({"type": "error", "message": error_msg}, request=request)
    finally:
        _clear_accelerator_cache()


def _last_user_prompt(messages: List[Dict[str, str]]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return coerce_string(message.get("content")).strip()
    return ""


def _write_wav(path: Path, audio: Any, sample_rate: int = 24000) -> None:
    """Write mono float audio to a 16-bit PCM WAV without external encoders."""
    import wave
    import numpy as np

    if hasattr(audio, "tolist"):
        audio_np = np.array(audio.tolist(), dtype=np.float32)
    else:
        audio_np = np.array(audio, dtype=np.float32)

    audio_np = np.squeeze(audio_np)
    if audio_np.ndim > 1:
        audio_np = audio_np.reshape(-1)

    audio_np = np.nan_to_num(audio_np, nan=0.0, posinf=0.0, neginf=0.0)
    audio_np = np.clip(audio_np, -1.0, 1.0)
    pcm = (audio_np * 32767.0).astype(np.int16)

    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm.tobytes())


def _generate_speech_segments(
    model: Any,
    adapter: str,
    text: str,
    cfg_scale: float,
    ddpm_steps: int,
    voice: str,
    speed: float,
    lang_code: str,
):
    """Try mlx-audio TTS generation with adapter-specific arguments."""
    if adapter == "kokoro":
        attempts = [
            {"text": text, "voice": voice, "speed": speed, "lang_code": lang_code},
            {"text": text, "voice": voice, "speed": speed},
            {"text": text, "voice": voice},
            {"text": text},
        ]
    elif adapter == "kugelaudio":
        attempts = [
            {
                "text": text,
                "voice": voice,
                "cfg_scale": cfg_scale,
                "ddpm_steps": ddpm_steps,
            },
            {"text": text, "voice": voice, "cfg_scale": cfg_scale},
            {"text": text, "cfg_scale": cfg_scale, "ddpm_steps": ddpm_steps},
            {"text": text, "cfg_scale": cfg_scale},
            {"text": text},
        ]
    else:
        attempts = [
            {
                "text": text,
                "voice": voice,
                "speed": speed,
                "lang_code": lang_code,
                "cfg_scale": cfg_scale,
                "ddpm_steps": ddpm_steps,
            },
            {"text": text, "voice": voice, "speed": speed, "lang_code": lang_code},
            {"text": text, "voice": voice},
            {"text": text},
        ]
    last_type_error = None

    for kwargs in attempts:
        try:
            yield from model.generate(**kwargs)
            return
        except TypeError as e:
            last_type_error = e

    try:
        yield from model.generate(text)
        return
    except TypeError as e:
        last_type_error = e

    if last_type_error is not None:
        raise last_type_error


def handle_image_generation(request: dict) -> None:
    """Handle image.generate request via mflux"""
    model_id = request.get("model")
    if not model_id:
        send_json({"type": "error", "message": "No model provided for image generation"}, request=request)
        return
    messages = request.get("messages", [])
    prompt = request.get("prompt") or _last_user_prompt(messages)
    image_paths = request.get("images", [])
    output_dir = Path(request.get("output_dir") or Path.home() / "Pictures" / "MLXtra")
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    width_value = _first_present_parameter(
        parameters.get("width"), request.get("width"), default=1024
    )
    height_value = _first_present_parameter(
        parameters.get("height"), request.get("height"), default=1024
    )
    steps_value = _first_present_parameter(
        parameters.get("steps"), request.get("steps"), default=4
    )
    guidance_value = _first_present_parameter(
        parameters.get("guidance"), request.get("guidance"), default=1.0
    )
    default_seed = time.time_ns() % 2_147_483_647
    seed_value = _first_present_parameter(
        parameters.get("seed"), request.get("seed"), default=default_seed
    )

    width = _coerce_positive_int_parameter(width_value, 1024)
    height = _coerce_positive_int_parameter(height_value, 1024)
    steps = _coerce_positive_int_parameter(steps_value, 4)
    guidance = _coerce_float_parameter(guidance_value, 1.0)
    seed = _coerce_int_parameter(
        seed_value,
        default_seed,
    )

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for image generation"},
            request=request,
        )
        return

    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        model = load_image_model_if_needed(
            model_id, edit=bool(image_paths), request=request
        )

        send_json(
            {"type": "model.loading", "model": model_id, "status": "generating"},
            request=request,
        )

        generation_kwargs = {
            "prompt": prompt,
            "seed": seed,
            "num_inference_steps": steps,
            "width": width,
            "height": height,
            "guidance": guidance,
        }

        if image_paths and hasattr(model, "generate_image"):
            generation_kwargs["image_paths"] = image_paths

        try:
            image = model.generate_image(**generation_kwargs)
        except TypeError:
            generation_kwargs.pop("image_paths", None)
            if image_paths:
                generation_kwargs["image_path"] = image_paths[0]
            try:
                image = model.generate_image(**generation_kwargs)
            except TypeError:
                generation_kwargs.pop("guidance", None)
                image = model.generate_image(**generation_kwargs)

        output_path = output_dir / f"{_safe_filename_component(model_id)}-{uuid.uuid4().hex}.png"
        image.save(str(output_path), overwrite=True)

        send_json(
            {
                "type": "image.generated",
                "path": str(output_path),
                "model": model_id,
                "seed": seed,
                "width": width,
                "height": height,
            },
            request=request,
        )
        send_json(
            {
                "type": "chat.completion.complete",
                "choices": [
                    {
                        "message": {
                            "content": f"Generated image with {model_id}. Seed: {seed}"
                        }
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            },
            request=request,
        )

    except Exception as e:
        error_msg = log_exception(
            "[Python Bridge] Image generation error", e, logger=log_debug
        )
        send_json({"type": "error", "message": error_msg}, request=request)
    finally:
        _clear_accelerator_cache()


def handle_audio_speech(request: dict) -> None:
    """Handle text-to-speech request via mlx-audio."""
    model_id = request.get("model")
    if not model_id:
        send_json({"type": "error", "message": "No model provided for speech generation"}, request=request)
        return
    messages = request.get("messages", [])
    text = str(
        request.get("input") or request.get("text") or _last_user_prompt(messages) or ""
    ).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXtra")
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    cfg_scale = _coerce_float_parameter(
        parameters.get("cfg_scale") or request.get("cfg_scale"),
        3.0,
    )
    ddpm_steps = _coerce_int_parameter(
        parameters.get("ddpm_steps") or request.get("ddpm_steps"),
        10,
    )
    voice = str(
        parameters.get("voice") or request.get("voice") or _audio_default_voice(request)
    ).strip()
    if not voice:
        voice = _audio_default_voice(request)
    speed = _coerce_float_parameter(
        parameters.get("speed") or request.get("speed"),
        1.0,
    )
    if speed <= 0:
        speed = 1.0
    lang_code = str(parameters.get("lang_code") or request.get("lang_code") or "").strip()
    if not lang_code and _audio_options_from_request(request).get("languageByVoicePrefix"):
        lang_code = _lang_code_for_voice(request, voice)

    if not text:
        send_json(
            {"type": "error", "message": "No text provided for speech generation"},
            request=request,
        )
        return

    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        model = load_audio_model_if_needed(model_id, request=request)

        send_json(
            {"type": "model.loading", "model": model_id, "status": "generating"},
            request=request,
        )

        output_path = output_dir / f"{_safe_filename_component(model_id)}-{uuid.uuid4().hex}.wav"
        audio_segments = []
        total_samples = 0
        sample_rate = 24000

        with contextlib.redirect_stdout(sys.stderr):
            adapter = _audio_adapter(request)
            _configure_espeak_runtime()
            for result in _generate_speech_segments(
                model, adapter, text, cfg_scale, ddpm_steps, voice, speed, lang_code
            ):
                audio = result.audio
                sample_rate = int(
                    getattr(result, "sample_rate", sample_rate) or sample_rate
                )
                audio_segments.append(audio)
                try:
                    total_samples += int(audio.shape[0])
                except Exception:
                    pass

        if not audio_segments:
            send_json(
                {"type": "error", "message": "Speech generation finished without audio"},
                request=request,
            )
            return

        if len(audio_segments) == 1:
            audio = audio_segments[0]
        else:
            import mlx.core as mx
            audio = mx.concatenate(audio_segments, axis=0)

        _write_wav(output_path, audio, sample_rate=sample_rate)

        send_json(
            {
                "type": "audio.generated",
                "path": str(output_path),
                "model": model_id,
                "sample_rate": sample_rate,
                "samples": total_samples,
            },
            request=request,
        )
        send_json(
            {
                "type": "chat.completion.complete",
                "choices": [
                    {"message": {"content": f"Generated speech with {model_id}."}}
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            },
            request=request,
        )

    except Exception as e:
        error_msg = log_exception(
            "[Python Bridge] Audio generation error", e, logger=log_debug
        )
        send_json({"type": "error", "message": error_msg}, request=request)
    finally:
        _clear_accelerator_cache()


def _terminate_child(child: subprocess.Popen, timeout: float = 5.0):
    if child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=1.0)


_music_process = None


def _ensure_music_subprocess(ace_python, helper_path):
    """Return a persistent, keep-alive ACE-Step subprocess."""
    global _music_process

    if _music_process is not None and _music_process.poll() is not None:
        _terminate_child(_music_process)
        _music_process = None

    if _music_process is None:
        _music_process = subprocess.Popen(
            [ace_python, str(helper_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=os.environ.copy(),
        )

    return _music_process


def _forward_music_request(child, request):
    """Send one request to a running music subprocess and relay response lines."""
    if child.stdin is None:
        raise RuntimeError("Subprocess stdin is None")
    child.stdin.write(json.dumps(request) + "\n")
    child.stdin.flush()

    saw_error = False
    request_id = request.get("request_id")
    terminal_message_types = {"chat.completion.complete", "error"}

    while True:
        if child.stdout is None:
            raise RuntimeError("Subprocess stdout is None")
        line = child.stdout.readline()
        if line == "":
            break

        stripped = line.strip()
        if stripped == "__DONE__":
            break

        if stripped:
            try:
                payload = json.loads(stripped)
                message_type = payload.get("type")
                payload_request_id = payload.get("request_id")
                saw_error = saw_error or message_type == "error"
                print(line, end="", flush=True)
                if message_type in terminal_message_types and (
                    request_id is None
                    or payload_request_id is None
                    or payload_request_id == request_id
                ):
                    break
            except json.JSONDecodeError:
                log_debug(f"[ACE-Step stdout ignored] {stripped}")

    returncode = child.poll()
    if returncode is not None and returncode != 0 and not saw_error:
        send_json(
            {"type": "error",
             "message": f"ACE-Step helper exited with code {returncode}"},
            request=request,
        )
    return returncode or 0



def _forward_acestep_subprocess(ace_python: str, helper_path: Path, request: dict) -> int:
    child = subprocess.Popen(
        [ace_python, str(helper_path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=os.environ.copy(),
    )

    def handle_parent_signal(signum, _frame):
        _terminate_child(child)
        raise SystemExit(128 + signum)

    previous_sigterm = signal.signal(signal.SIGTERM, handle_parent_signal)
    previous_sigint = signal.signal(signal.SIGINT, handle_parent_signal)
    saw_error = False
    selector = None

    try:
        if child.stdin is None:
            raise RuntimeError("Subprocess stdin is None")
        child.stdin.write(json.dumps(request) + "\n")
        child.stdin.close()

        selector = selectors.DefaultSelector()
        if child.stdout is not None:
            selector.register(child.stdout, selectors.EVENT_READ, "stdout")
        if child.stderr is not None:
            selector.register(child.stderr, selectors.EVENT_READ, "stderr")

        while selector.get_map():
            for key, _ in selector.select(timeout=0.1):
                line = key.fileobj.readline()
                if line == "":
                    selector.unregister(key.fileobj)
                    continue

                if key.data == "stdout":
                    stripped = line.strip()
                    if stripped:
                        try:
                            payload = json.loads(stripped)
                            saw_error = saw_error or payload.get("type") == "error"
                            print(line, end="", flush=True)
                        except json.JSONDecodeError:
                            log_debug(f"[ACE-Step stdout ignored] {stripped}")
                else:
                    log_debug(line.rstrip())

            if child.poll() is not None:
                for key in list(selector.get_map().values()):
                    fileobj = key.fileobj
                    remaining = fileobj.read()
                    if remaining:
                        if key.data == "stdout":
                            for line in remaining.splitlines():
                                stripped = line.strip()
                                if stripped:
                                    try:
                                        payload = json.loads(stripped)
                                        saw_error = saw_error or payload.get("type") == "error"
                                        print(line, flush=True)
                                    except json.JSONDecodeError:
                                        log_debug(f"[ACE-Step stdout ignored] {stripped}")
                        else:
                            log_debug(remaining.rstrip())
                    selector.unregister(fileobj)

        returncode = child.wait()
        if returncode != 0 and not saw_error:
            send_json(
                {
                    "type": "error",
                    "message": f"ACE-Step helper exited with code {returncode}",
                },
                request=request,
            )
        return returncode
    finally:
        if child.stdin is not None:
            child.stdin.close()
        if child.stdout is not None:
            child.stdout.close()
        if child.stderr is not None:
            child.stderr.close()
        if selector is not None:
            try:
                selector.close()
            except Exception:
                pass
        signal.signal(signal.SIGTERM, previous_sigterm)
        signal.signal(signal.SIGINT, previous_sigint)
        _terminate_child(child)


def _candidate_acestep_python_paths() -> List[Path]:
    candidates: List[Path] = []

    env_python = os.environ.get("ACESTEP_PYTHON")
    if env_python:
        candidates.append(Path(env_python))

    executable_path = Path(sys.executable)
    try:
        runtime_root = executable_path.resolve().parents[2]
    except IndexError:
        runtime_root = None
    if runtime_root is not None:
        candidates.append(runtime_root / "acestep-venv" / "bin" / "python")

    candidates.append(
        Path(__file__).parent
        / "runtime"
        / "macos-arm64"
        / "acestep-venv"
        / "bin"
        / "python"
    )

    return candidates


def _resolve_acestep_python() -> Optional[str]:
    seen: set[str] = set()
    current_python = Path(sys.executable).resolve()

    for candidate in _candidate_acestep_python_paths():
        try:
            resolved = candidate.resolve()
        except OSError:
            resolved = candidate

        candidate_key = str(resolved)
        if candidate_key in seen:
            continue
        seen.add(candidate_key)

        if not candidate.exists() or resolved == current_python:
            continue
        return str(resolved)

    return None


def handle_music_generation(request: dict) -> None:
    """Handle text-to-music request via ACE-Step 1.5."""
    ace_python = _resolve_acestep_python()

    if ace_python:
        helper_path = Path(__file__).with_name("acestep_bridge.py")
        _forward_acestep_subprocess(ace_python, helper_path, request)
        return

    send_json(
        {
            "type": "error",
            "message": (
                "Music runtime component is not installed. Install the music "
                "runtime from Models settings, then retry ACE-Step generation."
            ),
        },
        request=request,
    )
    return

    model_id = request.get("model")
    if not model_id:
        send_json({"type": "error", "message": "No model provided for music generation"}, request=request)
        return
    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    prompt = coerce_string(
        parameters.get("caption")
        or request.get("prompt")
        or _last_user_prompt(messages)
    ).strip()
    lyrics = coerce_string(parameters.get("lyrics")).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXtra")

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for music generation"},
            request=request,
        )
        return

    try:
        with contextlib.redirect_stdout(sys.stderr):
            from acestep.inference import GenerationConfig, GenerationParams, generate_music

        output_dir.mkdir(parents=True, exist_ok=True)
        dit_handler, llm_handler = load_music_model_if_needed(model_id, request=request)

        send_json(
            {"type": "model.loading", "model": model_id, "status": "generating"},
            request=request,
        )

        seed, params_kwargs, config_kwargs = build_acestep_generation_inputs(
            parameters,
            prompt=prompt,
            lyrics=lyrics,
            seed_default=time.time_ns() % 2_147_483_647,
        )
        config = GenerationConfig(**config_kwargs)

        with contextlib.redirect_stdout(sys.stderr):
            result = generate_music(
                dit_handler,
                llm_handler,
                GenerationParams(**params_kwargs),
                config,
                save_dir=str(output_dir),
            )

        if not result.success:
            message = result.error or result.status_message or "Music generation failed"
            send_json({"type": "error", "message": message}, request=request)
            return

        for audio in result.audios:
            path = audio.get("path")
            if path:
                send_json(
                    {
                        "type": "audio.generated",
                        "path": str(path),
                        "model": model_id,
                        "sample_rate": int(audio.get("sample_rate", 48000)),
                    },
                    request=request,
                )

        send_json(
            {
                "type": "chat.completion.complete",
                "choices": [
                    {
                        "message": {
                            "content": f"Generated music with ACE-Step. Seed: {seed}"
                        }
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            },
            request=request,
        )

    except Exception as e:
        error_msg = log_exception(
            "[Python Bridge] Music generation error", e, logger=log_debug
        )
        send_json({"type": "error", "message": error_msg}, request=request)


def handle_ping(request: dict) -> None:
    send_json({"type": "pong"}, request=request)


def handle_unload(request: dict) -> None:
    unload_models()
    send_json({"type": "model.unloaded"}, request=request)


def handle_init(request: dict) -> None:
    model_id = request.get("model_id", "")
    backend = request.get("backend", "vlm")
    if model_id:
        try:
            if backend == "image":
                load_image_model_if_needed(model_id, request=request)
            elif backend == "audio":
                load_audio_model_if_needed(model_id, request=request)
            elif backend == "music":
                # Music generation runs in an isolated ACE-Step process when available
                # because ACE-Step and the main MLX stack require incompatible package
                # versions. We don't load here eagerly - loading happens in the subprocess
                # when music.generate is called, which properly waits for initialization.
                send_json({"type": "model.initialized", "model": model_id}, request=request)
                return
            else:
                load_model_if_needed(model_id, request=request)
                send_json({"type": "model.initialized", "model": model_id}, request=request)
        except Exception as e:
            send_json(
                {"type": "error", "message": f"Failed to initialize model: {str(e)}"},
                request=request,
            )
    else:
        send_json({"type": "error", "message": "No model_id provided for init"}, request=request)


def handle_unknown(msg_type: str, request: Optional[dict] = None) -> None:
    send_json({"type": "error", "message": f"Unknown message type: {msg_type}"}, request=request)


def _cleanup():
    """Terminate subprocesses and release resources on bridge shutdown."""
    global _music_process
    try:
        if _music_process is not None:
            _terminate_child(_music_process)
            _music_process = None
    except Exception:
        pass  # Best-effort cleanup


def main():
    setup_environment()

    send_json({"type": "system.ready"})

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            request = None
            try:
                request = json.loads(line)
                msg_type = request.get("type")

                if msg_type == "chat.completions":
                    handle_chat_completion(request)
                elif msg_type == "image.generate":
                    handle_image_generation(request)
                elif msg_type == "audio.speech":
                    handle_audio_speech(request)
                elif msg_type == "music.generate":
                    handle_music_generation(request)
                elif msg_type == "init":
                    handle_init(request)
                elif msg_type == "ping":
                    handle_ping(request)
                elif msg_type == "unload":
                    handle_unload(request)
                else:
                    handle_unknown(msg_type, request=request)

            except json.JSONDecodeError as e:
                send_json({"type": "error", "message": f"Invalid JSON: {str(e)}"})
            except Exception as e:
                send_json(
                    {"type": "error", "message": f"Unexpected error: {str(e)}"},
                    request=request,
                )
    finally:
        _cleanup()


if __name__ == "__main__":
    main()
