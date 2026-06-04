#!/usr/bin/env python3
"""One-shot ACE-Step bridge used from the main MLXtra Python bridge."""

import contextlib
import importlib.util
import json
import math
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
    stream=None,
) -> None:
    payload = dict(obj)
    inherited_request_id = request_id if request_id is not None else get_request_id(request)
    if inherited_request_id:
        payload.setdefault("request_id", inherited_request_id)
    output_stream = stream if stream is not None else sys.stdout
    print(json.dumps(payload), file=output_stream, flush=True)


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


def _progress_fraction(fraction=None, percent=None) -> Optional[float]:
    value = fraction
    divisor = 1.0
    if value is None and percent is not None:
        value = percent
        divisor = 100.0
    try:
        number = float(value) / divisor
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return min(max(number, 0.0), 1.0)


def send_generation_progress(
    model_id: str,
    phase: str,
    *,
    request: Optional[dict] = None,
    message: Optional[str] = None,
    fraction=None,
    percent=None,
    estimated: bool = True,
    stream=None,
) -> None:
    progress_fraction = _progress_fraction(fraction=fraction, percent=percent)
    payload = {
        "type": "generation.progress",
        "model": model_id,
        "backend": "music",
        "phase": phase,
        "estimated": bool(estimated),
    }
    if message:
        payload["message"] = message
    if progress_fraction is not None:
        payload["fraction"] = progress_fraction
        payload["percent"] = int(round(progress_fraction * 100))
    send_json(payload, request=request, stream=stream)


def last_user_prompt(messages: list[dict]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return coerce_string(message.get("content")).strip()
    return ""


def generate_music_once(request: dict) -> bool:
    model_id = request.get("model")
    if not model_id:
        send_json({"type": "error", "message": "No model provided for music generation"}, request=request)
        return False
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
    json_stdout = sys.stdout

    send_generation_progress(
        model_id,
        "preparing",
        request=request,
        message="Preparing music generation",
        fraction=0.0,
        estimated=True,
    )

    def bridge_progress(value=None, desc=None, **_kwargs):
        send_generation_progress(
            model_id,
            "generating",
            request=request,
            message=coerce_string(desc, "Generating music"),
            fraction=value,
            estimated=True,
            stream=json_stdout,
        )

    with contextlib.redirect_stdout(sys.stderr):
        result = generate_music(
            dit_handler,
            llm_handler,
            GenerationParams(**params_kwargs),
            config,
            save_dir=str(output_dir),
            progress=bridge_progress,
        )

    if not result.success:
        message = result.error or result.status_message or "Music generation failed"
        send_json({"type": "error", "message": message}, request=request)
        return False

    for audio in result.audios:
        path = audio.get("path")
        if path:
            send_generation_progress(
                model_id,
                "finalizing",
                request=request,
                message="Preparing audio file",
                fraction=0.98,
                estimated=True,
            )
            send_json(
                {
                    "type": "audio.generated",
                    "path": str(path),
                    "model": model_id,
                    "sample_rate": int(audio.get("sample_rate", 48000)),
                },
                request=request,
            )

    send_generation_progress(
        model_id,
        "complete",
        request=request,
        message="Music complete",
        fraction=1.0,
        estimated=False,
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
