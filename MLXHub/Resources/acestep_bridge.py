#!/usr/bin/env python3
"""One-shot ACE-Step bridge used from the main MLXHub Python bridge."""

import contextlib
import importlib.util
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional

from bridge_utils import (
    coerce_bool,
    coerce_float,
    coerce_int,
    coerce_string,
    log_exception,
    normalize_music_model_id,
)


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
) -> None:
    payload = dict(obj)
    inherited_request_id = request_id if request_id is not None else get_request_id(request)
    if inherited_request_id:
        payload.setdefault("request_id", inherited_request_id)
    print(json.dumps(payload), flush=True)


def last_user_prompt(messages: list[dict]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return coerce_string(message.get("content")).strip()
    return ""


def generate_music_once(request: dict) -> None:
    with contextlib.redirect_stdout(sys.stderr):
        from acestep.handler import AceStepHandler
        from acestep.inference import GenerationConfig, GenerationParams, generate_music
        from acestep.llm_inference import LLMHandler

    model_id = request.get("model", "ACE-Step/acestep-v15-turbo-continuous")
    # Normalize the model ID for ACE-Step lookup
    normalized_id = normalize_music_model_id(model_id)

    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    prompt = coerce_string(
        parameters.get("caption") or request.get("prompt") or last_user_prompt(messages)
    ).strip()
    lyrics = coerce_string(parameters.get("lyrics")).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXHub")

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for music generation"},
            request=request,
        )
        return

    package_spec = importlib.util.find_spec("acestep")
    project_root = (
        Path(package_spec.origin).parent.parent
        if package_spec and package_spec.origin
        else Path.cwd()
    )
    config_path = os.environ.get("ACESTEP_CONFIG_PATH") or normalized_id

    send_json(
        {"type": "model.loading", "model": model_id, "status": "loading"},
        request=request,
    )
    with contextlib.redirect_stdout(sys.stderr):
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
            {"type": "error", "message": f"Model initialization failed: {error_msg}"},
            request=request,
        )
        return
    with contextlib.redirect_stdout(sys.stderr):
        llm_handler = LLMHandler()
    send_json({"type": "model.loaded", "model": model_id}, request=request)

    output_dir.mkdir(parents=True, exist_ok=True)
    seed = coerce_int(parameters.get("seed"), time.time_ns() % 2_147_483_647)
    thinking = coerce_bool(parameters.get("thinking"), False)
    instrumental = coerce_bool(parameters.get("instrumental"), False)
    params_kwargs = {
        "task_type": "text2music",
        "caption": prompt,
        "lyrics": lyrics,
        "duration": coerce_float(parameters.get("duration"), 30.0),
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

    send_json(
        {"type": "model.loading", "model": model_id, "status": "generating"},
        request=request,
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
                {"message": {"content": f"Generated music with ACE-Step. Seed: {seed}"}}
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
        },
        request=request,
    )


def main() -> None:
    request = None
    try:
        request = json.loads(sys.stdin.readline())
        generate_music_once(request)
    except Exception as exc:
        error_msg = log_exception("[ACE-Step Bridge] Unhandled error", exc)
        send_json({"type": "error", "message": error_msg}, request=request)


if __name__ == "__main__":
    main()
