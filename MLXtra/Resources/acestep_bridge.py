#!/usr/bin/env python3
"""One-shot ACE-Step bridge used from the main MLXtra Python bridge."""

import contextlib
import importlib.util
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional

from bridge_utils import (
    build_acestep_generation_inputs,
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


def send_model_loading(
    model_id: str,
    phase: str,
    *,
    request: Optional[dict] = None,
    detail: Optional[str] = None,
) -> None:
    payload = {
        "type": "model.loading",
        "model": model_id,
        "backend": "music",
        "status": phase,
        "phase": phase,
    }
    if detail:
        payload["detail"] = detail
    send_json(payload, request=request)


def last_user_prompt(messages: list[dict]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return coerce_string(message.get("content")).strip()
    return ""


def generate_music_once(request: dict) -> bool:
    model_id = request.get("model", "ACE-Step/acestep-v15-turbo-continuous")
    normalized_id = normalize_music_model_id(model_id)

    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    prompt = coerce_string(
        parameters.get("caption") or request.get("prompt") or last_user_prompt(messages)
    ).strip()
    lyrics = coerce_string(parameters.get("lyrics")).strip()
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXtra")

    if not prompt:
        send_json(
            {"type": "error", "message": "No prompt provided for music generation"},
            request=request,
        )
        return False

    with contextlib.redirect_stdout(sys.stderr):
        from acestep.handler import AceStepHandler
        from acestep.inference import GenerationConfig, GenerationParams, generate_music
        from acestep.llm_inference import LLMHandler

    package_spec = importlib.util.find_spec("acestep")
    project_root = (
        Path(package_spec.origin).parent.parent
        if package_spec and package_spec.origin
        else Path.cwd()
    )
    config_path = os.environ.get("ACESTEP_CONFIG_PATH") or normalized_id

    send_model_loading(
        model_id,
        "loading_weights",
        request=request,
        detail="Loading music model",
    )
    with contextlib.redirect_stdout(sys.stderr):
        dit_handler = AceStepHandler()
        init_result = dit_handler.initialize_service(
            project_root=str(project_root),
            config_path=str(config_path),
            device=os.environ.get("ACESTEP_DEVICE", "mps"),
        )
    if not init_result or init_result[1] is False:
        error_msg = init_result[0] if init_result else "Unknown initialization error"
        send_json(
            {"type": "error", "message": f"Model initialization failed: {error_msg}"},
            request=request,
        )
        return False
    with contextlib.redirect_stdout(sys.stderr):
        llm_handler = LLMHandler()
    send_model_loading(
        model_id,
        "warming",
        request=request,
        detail="Warming music model",
    )
    send_json({"type": "model.loaded", "model": model_id}, request=request)

    output_dir.mkdir(parents=True, exist_ok=True)
    seed, params_kwargs, config_kwargs = build_acestep_generation_inputs(
        parameters,
        prompt=prompt,
        lyrics=lyrics,
        seed_default=time.time_ns() % 2_147_483_647,
    )
    config = GenerationConfig(**config_kwargs)

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
        return False

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
    return True


def main() -> None:
    request = None
    try:
        request = json.loads(sys.stdin.readline())
        success = generate_music_once(request)
        if not success:
            raise SystemExit(1)
    except Exception as exc:
        error_msg = log_exception("[ACE-Step Bridge] Unhandled error", exc)
        send_json({"type": "error", "message": error_msg}, request=request)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
