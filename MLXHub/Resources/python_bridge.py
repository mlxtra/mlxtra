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
import time
import uuid
from typing import List, Dict, Optional, Any
from pathlib import Path

# Model registry for hot-swapping
MODEL_REGISTRY: Dict[str, Any] = {}
IMAGE_MODEL_REGISTRY: Dict[str, Any] = {}


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
        log_debug(f"[Python Bridge] Image model {cache_key} already loaded, using cache")
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

    chat_template_kwargs = request.get("chat_template_kwargs", {})

    try:
        model, processor, config = load_model_if_needed(model_id)

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

        # Qwen thinking templates can place the opening tag in the prompt, so the
        # model may stream reasoning content and the closing tag without echoing
        # "<think>". Keep the UI stream well-formed only when thinking is enabled.
        if enable_thinking:
            opening_tag = "<think>\n"
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
        send_json({"type": "error", "message": "No prompt provided for image generation"})
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


def handle_ping() -> None:
    send_json({"type": "pong"})


def handle_unload() -> None:
    import mlx.core as mx

    MODEL_REGISTRY.clear()
    IMAGE_MODEL_REGISTRY.clear()
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
