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
    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    prompt = (parameters.get("caption") or request.get("prompt") or last_user_prompt(messages)).strip()
    lyrics = (parameters.get("lyrics") or "").strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")

    if not prompt:
        send_json({"type": "error", "message": "No prompt provided for music generation"})
        return

    package_spec = importlib.util.find_spec("acestep")
    project_root = Path(package_spec.origin).parent.parent if package_spec and package_spec.origin else Path.cwd()
    config_path = os.environ.get("ACESTEP_CONFIG_PATH") or model_id

    send_json({"type": "model.loading", "model": model_id, "status": "loading"})
    dit_handler = AceStepHandler()
    dit_handler.initialize_service(
        project_root=str(project_root),
        config_path=str(config_path),
        device=os.environ.get("ACESTEP_DEVICE", "mps"),
    )
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
            "choices": [{"message": {"content": f"Generated music with ACE-Step. Seed: {seed}"}}],
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
