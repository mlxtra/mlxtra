#!/usr/bin/env python3
"""One-shot ACE-Step bridge used from the main MLXHub Python bridge."""

import contextlib
import importlib.util
import json
import os
import sys
import time
from pathlib import Path


def send_json(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def _normalize_music_model_id(model_id: str) -> str:
    """Normalize HuggingFace repo ID to local ACE-Step directory name.

    ACE-Step expects local directory names like 'acestep-v15-turbo',
    not HuggingFace repo IDs like 'ACE-Step/acestep-v15-turbo-continuous'.
    """
    # Strip HuggingFace organization prefix
    if model_id.startswith("ACE-Step/"):
        model_id = model_id[len("ACE-Step/") :]

    # Map variant suffixes to base model name
    # The local directory is 'acestep-v15-turbo' for all turbo variants
    if model_id.startswith("acestep-v15-turbo"):
        return "acestep-v15-turbo"

    return model_id


def last_user_prompt(messages: list[dict]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return message.get("content", "").strip()
    return ""


def generate_music_once(request: dict) -> None:
    from acestep.handler import AceStepHandler
    from acestep.inference import GenerationConfig, GenerationParams, generate_music
    from acestep.llm_inference import LLMHandler

    model_id = request.get("model", "ACE-Step/acestep-v15-turbo-continuous")
    # Normalize the model ID for ACE-Step lookup
    normalized_id = _normalize_music_model_id(model_id)

    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    prompt = (
        parameters.get("caption") or request.get("prompt") or last_user_prompt(messages)
    ).strip()
    lyrics = (parameters.get("lyrics") or "").strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for music generation"}
        )
        return

    package_spec = importlib.util.find_spec("acestep")
    project_root = (
        Path(package_spec.origin).parent.parent
        if package_spec and package_spec.origin
        else Path.cwd()
    )
    config_path = os.environ.get("ACESTEP_CONFIG_PATH") or normalized_id

    send_json({"type": "model.loading", "model": model_id, "status": "loading"})
    dit_handler = AceStepHandler()
    init_result = dit_handler.initialize_service(
        project_root=str(project_root),
        config_path=str(config_path),
        device=os.environ.get("ACESTEP_DEVICE", "mps"),
    )
    # Check if initialization succeeded
    if not init_result or init_result[1] is False:
        error_msg = init_result[0] if init_result else "Unknown initialization error"
        send_json(
            {"type": "error", "message": f"Model initialization failed: {error_msg}"}
        )
        return
    llm_handler = LLMHandler()
    send_json({"type": "model.loaded", "model": model_id})

    output_dir.mkdir(parents=True, exist_ok=True)
    seed = int(parameters.get("seed") or (time.time_ns() % 2_147_483_647))
    params_kwargs = {
        "task_type": "text2music",
        "caption": prompt,
        "lyrics": lyrics,
        "duration": float(parameters.get("duration", 30)),
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
    if parameters.get("bpm"):
        params_kwargs["bpm"] = int(parameters["bpm"])
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

    send_json({"type": "model.loading", "model": model_id, "status": "generating"})
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
                {"message": {"content": f"Generated music with ACE-Step. Seed: {seed}"}}
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
        }
    )


def main() -> None:
    try:
        request = json.loads(sys.stdin.readline())
        generate_music_once(request)
    except Exception as exc:
        import traceback

        send_json({"type": "error", "message": f"{exc}\n{traceback.format_exc()}"})


if __name__ == "__main__":
    main()
