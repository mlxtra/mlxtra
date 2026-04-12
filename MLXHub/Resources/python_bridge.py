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
import subprocess
import time
import uuid
import contextlib
from typing import List, Dict, Optional, Any
from pathlib import Path

# Model registry for hot-swapping
MODEL_REGISTRY: Dict[str, Any] = {}
IMAGE_MODEL_REGISTRY: Dict[str, Any] = {}
AUDIO_MODEL_REGISTRY: Dict[str, Any] = {}
MUSIC_MODEL_REGISTRY: Dict[str, Any] = {}


def log_debug(msg: str):
    """Log debug message to stderr (not stdout, which is for JSON only)"""
    print(msg, file=sys.stderr, flush=True)


def send_json(obj: dict):
    """Send JSON object to stdout (only valid JSON goes to stdout)"""
    print(json.dumps(obj), flush=True)


def setup_environment():
    """Setup Python environment for bundled runtime"""
    bundle_dir = Path(__file__).parent.parent
    venv_path = bundle_dir / "runtime" / "macos-arm64" / "venv"

    if venv_path.exists():
        for py_version in ["python3.13", "python3.12", "python3.11"]:
            site_packages = venv_path / "lib" / py_version / "site-packages"
            if site_packages.exists():
                sys.path.insert(0, str(site_packages))
                break


def load_model_if_needed(model_id: str):
    """Lazy load model, cache in registry"""
    if model_id in MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Model {model_id} already loaded, using cache")
        return MODEL_REGISTRY[model_id]

    from mlx_vlm import load
    from mlx_vlm.utils import load_config

    send_json({"type": "model.loading", "model": model_id, "status": "downloading"})

    try:
        log_debug(f"[Python Bridge] Loading model: {model_id}")
        model, processor = load(model_id)
        config = load_config(model_id)

        MODEL_REGISTRY[model_id] = (model, processor, config)

        send_json({"type": "model.loaded", "model": model_id})
        log_debug(f"[Python Bridge] Model {model_id} loaded successfully")

        return model, processor, config
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load model {model_id}: {str(e)}")
        raise


def load_image_model_if_needed(model_id: str, edit: bool = False):
    """Lazy load mflux image model, cache in registry"""
    cache_key = f"{model_id}:{'edit' if edit else 'txt2img'}"
    if cache_key in IMAGE_MODEL_REGISTRY:
        log_debug(
            f"[Python Bridge] Image model {cache_key} already loaded, using cache"
        )
        return IMAGE_MODEL_REGISTRY[cache_key]

    send_json({"type": "model.loading", "model": model_id, "status": "downloading"})

    try:
        log_debug(f"[Python Bridge] Loading image model: {model_id}")

        from mflux.models.common.config import ModelConfig
        from mflux.models.flux2.variants import Flux2Klein, Flux2KleinEdit

        model_class = Flux2KleinEdit if edit else Flux2Klein
        model = model_class(model_config=ModelConfig.flux2_klein_4b())

        IMAGE_MODEL_REGISTRY[cache_key] = model

        send_json({"type": "model.loaded", "model": model_id})
        log_debug(f"[Python Bridge] Image model {model_id} loaded successfully")

        return model
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load image model {model_id}: {str(e)}")
        raise


def load_audio_model_if_needed(model_id: str):
    """Lazy load mlx-audio TTS model, cache in registry"""
    if model_id in AUDIO_MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Audio model {model_id} already loaded, using cache")
        return AUDIO_MODEL_REGISTRY[model_id]

    send_json({"type": "model.loading", "model": model_id, "status": "downloading"})

    try:
        log_debug(f"[Python Bridge] Loading audio model: {model_id}")
        from mlx_audio.tts.utils import load_model

        model = load_model(model_id)
        AUDIO_MODEL_REGISTRY[model_id] = model

        send_json({"type": "model.loaded", "model": model_id})
        log_debug(f"[Python Bridge] Audio model {model_id} loaded successfully")

        return model
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load audio model {model_id}: {str(e)}")
        raise


def load_music_model_if_needed(model_id: str):
    """Lazy load ACE-Step music generation handlers."""
    if model_id in MUSIC_MODEL_REGISTRY:
        log_debug(f"[Python Bridge] Music model {model_id} already loaded, using cache")
        return MUSIC_MODEL_REGISTRY[model_id]

    send_json({"type": "model.loading", "model": model_id, "status": "downloading"})

    try:
        log_debug(f"[Python Bridge] Loading music model: {model_id}")
        import importlib.util

        from acestep.handler import AceStepHandler
        from acestep.llm_inference import LLMHandler

        package_spec = importlib.util.find_spec("acestep")
        project_root = Path(package_spec.origin).parent.parent if package_spec and package_spec.origin else Path.cwd()

        config_path = os.environ.get("ACESTEP_CONFIG_PATH") or model_id

        dit_handler = AceStepHandler()
        dit_handler.initialize_service(
            project_root=str(project_root),
            config_path=str(config_path),
            device=os.environ.get("ACESTEP_DEVICE", "mps"),
        )

        llm_handler = LLMHandler()
        MUSIC_MODEL_REGISTRY[model_id] = (dit_handler, llm_handler)

        send_json({"type": "model.loaded", "model": model_id})
        log_debug(f"[Python Bridge] Music model {model_id} loaded successfully")

        return dit_handler, llm_handler
    except Exception as e:
        log_debug(f"[Python Bridge] Failed to load music model {model_id}: {str(e)}")
        raise


def _normalize_messages(messages: list) -> list:
    """Ensure tool_call.function.arguments is a dict, not a JSON string.

    Some templates (e.g. Qwen3.5) call |items on arguments, which only
    works on mappings. The OpenAI spec allows arguments as a JSON string,
    so we convert it here.
    """
    normalized = []
    for msg in messages:
        msg = dict(msg)
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
    return normalized


def parse_tool_calls(text: str) -> List[Dict[str, Any]]:
    """Parse tool calls from model output. Tries common template formats."""
    tool_calls = []

    # Qwen3.5 format: <function=name>\n<parameter=key>\nvalue\n</parameter>\n</function>
    fn_pattern = re.compile(r"<function=([^>]+)>(.*?)</function>", re.DOTALL)
    for m in fn_pattern.finditer(text):
        fn_name = m.group(1).strip()
        fn_body = m.group(2)
        args = {}
        param_pattern = re.compile(r"<parameter=([^>]+)>(.*?)</parameter>", re.DOTALL)
        for p in param_pattern.finditer(fn_body):
            args[p.group(1).strip()] = p.group(2).strip()
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {"name": fn_name, "arguments": json.dumps(args)},
            }
        )

    if tool_calls:
        return tool_calls

    # Gemma 4 format: <|tool_call|>call:name(param: "value")<|tool_call|>
    gemma_pattern = re.compile(
        r"<\|tool_call\|>call:([^(\s]+)\((.*?)\)\s*<\|tool_call\|>", re.DOTALL
    )
    for m in gemma_pattern.finditer(text):
        fn_name = m.group(1).strip()
        args_str = m.group(2).strip()
        args = {}
        for pair in re.finditer(r'(\w+):\s*"([^"]*)"', args_str):
            args[pair.group(1)] = pair.group(2)
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
        model, processor, config = load_model_if_needed(model_id)

        if tools:
            normalized_messages = _normalize_messages(messages)
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
                messages,
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
                }
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
                }
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
                }
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
                }
            )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        import traceback

        error_msg = str(e)
        error_traceback = traceback.format_exc()
        log_debug(f"[Python Bridge] Error: {error_msg}")
        send_json({"type": "error", "message": f"{error_msg}\n{error_traceback}"})


def _last_user_prompt(messages: List[Dict[str, str]]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return message.get("content", "").strip()
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


def _generate_speech_segments(model: Any, text: str, cfg_scale: float, ddpm_steps: int, voice: str):
    """Try mlx-audio TTS generation with model-specific KugelAudio-friendly args."""
    attempts = [
        {"text": text, "voice": voice, "cfg_scale": cfg_scale, "ddpm_steps": ddpm_steps},
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
    width = int(request.get("width", 1024))
    height = int(request.get("height", 1024))
    steps = int(request.get("steps", 4))
    seed = int(request.get("seed") or (time.time_ns() % 2_147_483_647))

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for image generation"}
        )
        return

    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        model = load_image_model_if_needed(model_id, edit=bool(image_paths))

        send_json({"type": "model.loading", "model": model_id, "status": "generating"})

        generation_kwargs = {
            "prompt": prompt,
            "seed": seed,
            "num_inference_steps": steps,
            "width": width,
            "height": height,
        }

        if image_paths and hasattr(model, "generate_image"):
            generation_kwargs["image_paths"] = image_paths

        try:
            image = model.generate_image(**generation_kwargs)
        except TypeError:
            generation_kwargs.pop("image_paths", None)
            if image_paths:
                generation_kwargs["image_path"] = image_paths[0]
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
            }
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
            }
        )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        import traceback

        error_msg = str(e)
        error_traceback = traceback.format_exc()
        log_debug(f"[Python Bridge] Image generation error: {error_msg}")
        send_json({"type": "error", "message": f"{error_msg}\n{error_traceback}"})


def handle_audio_speech(request: dict) -> None:
    """Handle text-to-speech request via mlx-audio."""
    import mlx.core as mx

    model_id = request.get("model", "kugelaudio/kugelaudio-0-open")
    messages = request.get("messages", [])
    text = (request.get("input") or request.get("text") or _last_user_prompt(messages)).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")
    cfg_scale = float(request.get("cfg_scale", 3.0))
    ddpm_steps = int(request.get("ddpm_steps", 10))
    voice = request.get("voice", "default")

    if not text:
        send_json({"type": "error", "message": "No text provided for speech generation"})
        return

    try:
        output_dir.mkdir(parents=True, exist_ok=True)
        model = load_audio_model_if_needed(model_id)

        send_json({"type": "model.loading", "model": model_id, "status": "generating"})

        output_path = output_dir / f"kugelaudio-{uuid.uuid4().hex}.wav"
        audio_segments = []
        total_samples = 0
        sample_rate = 24000

        with contextlib.redirect_stdout(sys.stderr):
            for result in _generate_speech_segments(model, text, cfg_scale, ddpm_steps, voice):
                audio = result.audio
                sample_rate = int(getattr(result, "sample_rate", sample_rate) or sample_rate)
                audio_segments.append(audio)
                try:
                    total_samples += int(audio.shape[0])
                except Exception:
                    pass

        if not audio_segments:
            send_json({"type": "error", "message": "Speech generation finished without audio"})
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
            }
        )
        send_json(
            {
                "type": "chat.completion.complete",
                "choices": [
                    {
                        "message": {
                            "content": "Generated speech with KugelAudio."
                        }
                    }
                ],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0},
            }
        )

        mx.clear_cache()
        gc.collect()

    except Exception as e:
        import traceback

        error_msg = str(e)
        error_traceback = traceback.format_exc()
        log_debug(f"[Python Bridge] Audio generation error: {error_msg}")
        send_json({"type": "error", "message": f"{error_msg}\n{error_traceback}"})


def handle_music_generation(request: dict) -> None:
    """Handle text-to-music request via ACE-Step 1.5."""
    ace_python = os.environ.get("ACESTEP_PYTHON")
    if not ace_python:
        ace_python_path = Path(__file__).parent.parent / "runtime" / "macos-arm64" / "acestep-venv" / "bin" / "python"
        if ace_python_path.exists():
            ace_python = str(ace_python_path)

    if ace_python and Path(ace_python).exists() and Path(ace_python) != Path(sys.executable):
        helper_path = Path(__file__).with_name("acestep_bridge.py")
        child = subprocess.Popen(
            [ace_python, str(helper_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=os.environ.copy(),
        )
        payload = json.dumps(request) + "\n"
        stdout, stderr = child.communicate(payload)
        if stderr:
            log_debug(stderr.rstrip())
        for line in stdout.splitlines():
            if line.strip():
                print(line, flush=True)
        if child.returncode != 0:
            send_json({"type": "error", "message": f"ACE-Step helper exited with code {child.returncode}"})
        return

    model_id = request.get("model", "ACE-Step/acestep-v15-turbo-continuous")
    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    prompt = (parameters.get("caption") or request.get("prompt") or _last_user_prompt(messages)).strip()
    lyrics = (parameters.get("lyrics") or "").strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")

    if not prompt:
        send_json({"type": "error", "message": "No prompt provided for music generation"})
        return

    try:
        from acestep.inference import GenerationConfig, GenerationParams, generate_music

        output_dir.mkdir(parents=True, exist_ok=True)
        dit_handler, llm_handler = load_music_model_if_needed(model_id)

        send_json({"type": "model.loading", "model": model_id, "status": "generating"})

        seed = int(parameters.get("seed") or (time.time_ns() % 2_147_483_647))
        duration = float(parameters.get("duration", 30))
        bpm = parameters.get("bpm")

        params_kwargs = {
            "task_type": "text2music",
            "caption": prompt,
            "lyrics": lyrics,
            "duration": duration,
            "inference_steps": int(parameters.get("inference_steps", 8)),
            "seed": seed,
            "shift": float(parameters.get("shift", 3.0)),
            "infer_method": parameters.get("infer_method", "ode"),
            "thinking": bool(parameters.get("thinking", False)),
            "use_cot_metas": bool(parameters.get("thinking", False)),
            "use_cot_caption": bool(parameters.get("thinking", False)),
            "use_cot_lyrics": False,
            "use_cot_language": bool(parameters.get("thinking", False)),
            "instrumental": bool(parameters.get("instrumental", False)),
        }
        if bpm:
            params_kwargs["bpm"] = int(bpm)
        if parameters.get("keyscale"):
            params_kwargs["keyscale"] = parameters["keyscale"]
        if parameters.get("vocal_language"):
            params_kwargs["vocal_language"] = parameters["vocal_language"]

        config = GenerationConfig(
            batch_size=int(parameters.get("batch_size", 1)),
            audio_format=parameters.get("audio_format", "wav"),
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
            send_json({"type": "error", "message": message})
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
                    }
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
            }
        )
        gc.collect()

    except Exception as e:
        import traceback

        error_msg = str(e)
        error_traceback = traceback.format_exc()
        log_debug(f"[Python Bridge] Music generation error: {error_msg}")
        send_json({"type": "error", "message": f"{error_msg}\n{error_traceback}"})


def handle_ping() -> None:
    send_json({"type": "pong"})


def handle_unload() -> None:
    import mlx.core as mx

    MODEL_REGISTRY.clear()
    IMAGE_MODEL_REGISTRY.clear()
    AUDIO_MODEL_REGISTRY.clear()
    MUSIC_MODEL_REGISTRY.clear()
    mx.clear_cache()
    gc.collect()
    send_json({"type": "model.unloaded"})


def handle_init(request: dict) -> None:
    model_id = request.get("model_id", "")
    backend = request.get("backend", "vlm")
    if model_id:
        try:
            if backend == "image":
                load_image_model_if_needed(model_id)
            elif backend == "audio":
                load_audio_model_if_needed(model_id)
            elif backend == "music":
                # Music generation runs in an isolated ACE-Step process when available
                # because ACE-Step and the main MLX stack require incompatible package
                # versions.
                send_json({"type": "model.initialized", "model": model_id})
                return
            else:
                load_model_if_needed(model_id)
            send_json({"type": "model.initialized", "model": model_id})
        except Exception as e:
            send_json(
                {"type": "error", "message": f"Failed to initialize model: {str(e)}"}
            )
    else:
        send_json({"type": "error", "message": "No model_id provided for init"})


def handle_unknown(msg_type: str) -> None:
    send_json({"type": "error", "message": f"Unknown message type: {msg_type}"})


def main():
    setup_environment()

    send_json({"type": "system.ready"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

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
                handle_ping()
            elif msg_type == "unload":
                handle_unload()
            else:
                handle_unknown(msg_type)

        except json.JSONDecodeError as e:
            send_json({"type": "error", "message": f"Invalid JSON: {str(e)}"})
        except Exception as e:
            send_json({"type": "error", "message": f"Unexpected error: {str(e)}"})


if __name__ == "__main__":
    main()
