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
import re
import signal
import selectors
import subprocess
import time
import uuid
import contextlib
from typing import List, Dict, Optional, Any
from pathlib import Path

from bridge_utils import (
    coerce_bool,
    coerce_float,
    coerce_int,
    coerce_string,
    log_exception,
    normalize_music_model_id,
)

# Model registry for hot-swapping
MODEL_REGISTRY: Dict[str, Any] = {}
IMAGE_MODEL_REGISTRY: Dict[str, Any] = {}
AUDIO_MODEL_REGISTRY: Dict[str, Any] = {}
MUSIC_MODEL_REGISTRY: Dict[str, Any] = {}


def log_debug(msg: str):
    """Log debug message to stderr (not stdout, which is for JSON only)"""
    print(msg, file=sys.stderr, flush=True)


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


def setup_environment():
    """Setup Python environment for bundled runtime"""
    resources_dir = Path(__file__).resolve().parent
    venv_path = resources_dir / "runtime" / "macos-arm64" / "venv"

    if venv_path.exists():
        for py_version in ["python3.13", "python3.12", "python3.11"]:
            site_packages = venv_path / "lib" / py_version / "site-packages"
            if site_packages.exists():
                sys.path.insert(0, str(site_packages))
                break


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
        unload_models(keep_registry=MODEL_REGISTRY, keep_key=model_id)
        return MODEL_REGISTRY[model_id]

    from mlx_vlm import load
    from mlx_vlm.utils import load_config

    send_json(
        {"type": "model.loading", "model": model_id, "status": "downloading"},
        request=request,
    )

    try:
        unload_models()
        log_debug(f"[Python Bridge] Loading model: {model_id}")
        model, processor = load(model_id)
        config = load_config(model_id)

        MODEL_REGISTRY[model_id] = (model, processor, config)

        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Model {model_id} loaded successfully")

        return model, processor, config
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load model {model_id}: {str(e)}")
        raise


def load_image_model_if_needed(
    model_id: str, edit: bool = False, request: Optional[dict] = None
):
    """Lazy load mflux image model, cache in registry"""
    cache_key = f"{model_id}:{'edit' if edit else 'txt2img'}"
    if cache_key in IMAGE_MODEL_REGISTRY:
        log_debug(
            f"[Python Bridge] Image model {cache_key} already loaded, using cache"
        )
        unload_models(keep_registry=IMAGE_MODEL_REGISTRY, keep_key=cache_key)
        return IMAGE_MODEL_REGISTRY[cache_key]

    send_json(
        {"type": "model.loading", "model": model_id, "status": "downloading"},
        request=request,
    )

    try:
        unload_models()
        log_debug(f"[Python Bridge] Loading image model: {model_id}")

        from mflux.models.common.config import ModelConfig
        from mflux.models.flux2.variants import Flux2Klein, Flux2KleinEdit

        model_class = Flux2KleinEdit if edit else Flux2Klein
        model = model_class(
            model_path=model_id, model_config=ModelConfig.flux2_klein_4b()
        )

        IMAGE_MODEL_REGISTRY[cache_key] = model

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
        unload_models(keep_registry=AUDIO_MODEL_REGISTRY, keep_key=model_id)
        return AUDIO_MODEL_REGISTRY[model_id]

    send_json(
        {"type": "model.loading", "model": model_id, "status": "downloading"},
        request=request,
    )

    try:
        unload_models()
        log_debug(f"[Python Bridge] Loading audio model: {model_id}")
        from mlx_audio.tts.utils import load_model

        model = load_model(model_id)
        AUDIO_MODEL_REGISTRY[model_id] = model

        send_json({"type": "model.loaded", "model": model_id}, request=request)
        log_debug(f"[Python Bridge] Audio model {model_id} loaded successfully")

        return model
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load audio model {model_id}: {str(e)}")
        raise


def load_music_model_if_needed(model_id: str, request: Optional[dict] = None):
    """Lazy load ACE-Step music generation handlers."""
    # Normalize the model ID for ACE-Step lookup
    normalized_id = normalize_music_model_id(model_id)

    if model_id in MUSIC_MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Music model {model_id} already loaded, using cache")
        unload_models(keep_registry=MUSIC_MODEL_REGISTRY, keep_key=model_id)
        return MUSIC_MODEL_REGISTRY[model_id]

    send_json(
        {"type": "model.loading", "model": model_id, "status": "downloading"},
        request=request,
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
    from mlx_vlm import stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    import mlx.core as mx

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
        model, processor, config = load_model_if_needed(model_id, request=request)
        normalized_messages = _normalize_messages(messages)

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

        log_debug(f"[Python Bridge] Prompt: {prompt[:200]}...")

        full_response = ""
        prompt_tokens = 0
        completion_tokens = 0
        enable_thinking = bool(chat_template_kwargs.get("enable_thinking", False))

        if enable_thinking:
            opening_tag = "<tool_call>\n"
            send_json(
                {
                    "type": "chat.completion.chunk",
                    "choices": [{"delta": {"content": opening_tag}}],
                },
                request=request,
            )
            full_response = opening_tag

        for chunk in stream_generate(
            model,
            processor,
            prompt,
            image=images if images else None,
            max_tokens=max_tokens,
            temperature=temperature,
            top_p=top_p,
            top_k=top_k,
            min_p=min_p,
            repetition_penalty=repetition_penalty,
            verbose=False,
        ):
            token = chunk.text
            full_response += token
            prompt_tokens = chunk.prompt_tokens
            completion_tokens = chunk.generation_tokens

            send_json(
                {
                    "type": "chat.completion.chunk",
                    "choices": [{"delta": {"content": token}}],
                },
                request=request,
            )

        parsed_tool_calls = parse_tool_calls(full_response)

        if parsed_tool_calls:
            send_json(
                {
                    "type": "chat.completion.tool_calls",
                    "tool_calls": parsed_tool_calls,
                    "content": full_response,
                    "usage": {
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                    },
                },
                request=request,
            )
        else:
            send_json(
                {
                    "type": "chat.completion.complete",
                    "choices": [{"message": {"content": full_response}}],
                    "usage": {
                        "prompt_tokens": prompt_tokens,
                        "completion_tokens": completion_tokens,
                    },
                },
                request=request,
            )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        error_msg = log_exception("[Python Bridge] Error", e, logger=log_debug)
        send_json({"type": "error", "message": error_msg}, request=request)


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
    model: Any, text: str, cfg_scale: float, ddpm_steps: int, voice: str
):
    """Try mlx-audio TTS generation with model-specific KugelAudio-friendly args."""
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
    import mlx.core as mx

    model_id = request.get("model", "black-forest-labs/FLUX.2-klein-4B")
    messages = request.get("messages", [])
    prompt = request.get("prompt") or _last_user_prompt(messages)
    image_paths = request.get("images", [])
    output_dir = Path(request.get("output_dir") or Path.home() / "Pictures" / "MLXHub")
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    width = int(parameters.get("width") or request.get("width", 1024))
    height = int(parameters.get("height") or request.get("height", 1024))
    steps = int(parameters.get("steps") or request.get("steps", 4))
    guidance = float(parameters.get("guidance") or request.get("guidance", 1.0))
    seed = int(parameters.get("seed") or request.get("seed") or (time.time_ns() % 2_147_483_647))

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

        output_path = output_dir / f"flux2-klein-{uuid.uuid4().hex}.png"
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
                            "content": f"Generated image with FLUX.2-klein-4B. Seed: {seed}"
                        }
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            },
            request=request,
        )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        error_msg = log_exception(
            "[Python Bridge] Image generation error", e, logger=log_debug
        )
        send_json({"type": "error", "message": error_msg}, request=request)


def handle_audio_speech(request: dict) -> None:
    """Handle text-to-speech request via mlx-audio."""
    import mlx.core as mx

    model_id = request.get("model", "kugelaudio/kugelaudio-0-open")
    messages = request.get("messages", [])
    text = (
        request.get("input") or request.get("text") or _last_user_prompt(messages)
    ).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    cfg_scale = float(parameters.get("cfg_scale") or request.get("cfg_scale", 3.0))
    ddpm_steps = int(parameters.get("ddpm_steps") or request.get("ddpm_steps", 10))
    voice = parameters.get("voice") or request.get("voice", "default")

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

        output_path = output_dir / f"kugelaudio-{uuid.uuid4().hex}.wav"
        audio_segments = []
        total_samples = 0
        sample_rate = 24000

        with contextlib.redirect_stdout(sys.stderr):
            for result in _generate_speech_segments(
                model, text, cfg_scale, ddpm_steps, voice
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
                    {"message": {"content": "Generated speech with KugelAudio."}}
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            },
            request=request,
        )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        error_msg = log_exception(
            "[Python Bridge] Audio generation error", e, logger=log_debug
        )
        send_json({"type": "error", "message": error_msg}, request=request)


def _terminate_child(child: subprocess.Popen, timeout: float = 5.0):
    if child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=1.0)


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
        assert child.stdin is not None
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


def handle_music_generation(request: dict) -> None:
    """Handle text-to-music request via ACE-Step 1.5."""
    ace_python = os.environ.get("ACESTEP_PYTHON")
    if not ace_python:
        ace_python_path = (
            Path(__file__).parent
            / "runtime"
            / "macos-arm64"
            / "acestep-venv"
            / "bin"
            / "python"
        )
        if ace_python_path.exists():
            ace_python = str(ace_python_path)

    if (
        ace_python
        and Path(ace_python).exists()
        and Path(ace_python) != Path(sys.executable)
    ):
        helper_path = Path(__file__).with_name("acestep_bridge.py")
        _forward_acestep_subprocess(ace_python, helper_path, request)
        return

    model_id = request.get("model", "ACE-Step/acestep-v15-turbo-continuous")
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
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")

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

        seed = coerce_int(parameters.get("seed"), time.time_ns() % 2_147_483_647)
        duration = coerce_float(parameters.get("duration"), 30.0)
        thinking = coerce_bool(parameters.get("thinking"), False)
        instrumental = coerce_bool(parameters.get("instrumental"), False)

        params_kwargs = {
            "task_type": "text2music",
            "caption": prompt,
            "lyrics": lyrics,
            "duration": duration,
            "inference_steps": coerce_int(parameters.get("inference_steps"), 8),
            "seed": seed,
            "shift": coerce_float(parameters.get("shift"), 3.0),
            "infer_method": coerce_string(parameters.get("infer_method"), "ode") or "ode",
            "thinking": thinking,
            "use_cot_metas": thinking,
            "use_cot_caption": thinking,
            "use_cot_lyrics": False,
            "use_cot_language": thinking,
            "instrumental": instrumental,
        }
        bpm = coerce_int(parameters.get("bpm"), 0)
        if bpm:
            params_kwargs["bpm"] = bpm
        keyscale = coerce_string(parameters.get("keyscale")).strip()
        if keyscale:
            params_kwargs["keyscale"] = keyscale
        timesignature = coerce_string(parameters.get("timesignature")).strip()
        if timesignature:
            params_kwargs["timesignature"] = timesignature
        vocal_language = coerce_string(parameters.get("vocal_language")).strip()
        if vocal_language and vocal_language != "unknown":
            params_kwargs["vocal_language"] = vocal_language

        config = GenerationConfig(
            batch_size=coerce_int(parameters.get("batch_size"), 1),
            audio_format=coerce_string(parameters.get("audio_format"), "wav") or "wav",
            use_random_seed=False,
            seeds=[seed],
        )

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
        gc.collect()

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


def main():
    setup_environment()

    send_json({"type": "system.ready"})

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


if __name__ == "__main__":
    main()
