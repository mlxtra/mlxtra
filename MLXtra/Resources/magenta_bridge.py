#!/usr/bin/env python3
"""One-shot Magenta RealTime 2 bridge used from the main MLXtra Python bridge."""

import contextlib
import json
import math
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Optional

from bridge_utils import coerce_string, log_exception


MODEL_PREFIX = "google/magenta-realtime-2/"
SUPPORTED_MODELS = {"mrt2_small", "mrt2_base"}


def get_request_id(request: Optional[dict] = None) -> Optional[str]:
    if not isinstance(request, dict):
        return None
    request_id = request.get("request_id")
    return None if request_id is None else str(request_id)


def send_json(obj: dict, *, request: Optional[dict] = None) -> None:
    payload = dict(obj)
    request_id = get_request_id(request)
    if request_id:
        payload.setdefault("request_id", request_id)
    print(json.dumps(payload), file=sys.stdout, flush=True)


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


def send_generation_progress(
    model_id: str,
    phase: str,
    *,
    request: Optional[dict] = None,
    message: Optional[str] = None,
    fraction: Optional[float] = None,
    estimated: bool = True,
) -> None:
    payload = {
        "type": "generation.progress",
        "model": model_id,
        "backend": "music",
        "phase": phase,
        "estimated": estimated,
    }
    if message:
        payload["message"] = message
    if fraction is not None and math.isfinite(fraction):
        normalized = min(max(float(fraction), 0.0), 1.0)
        payload["fraction"] = normalized
        payload["percent"] = int(round(normalized * 100))
    send_json(payload, request=request)


def last_user_prompt(messages: list[dict]) -> str:
    for message in reversed(messages):
        if message.get("role") == "user":
            return coerce_string(message.get("content")).strip()
    return ""


def model_name(model_id: Any) -> Optional[str]:
    value = coerce_string(model_id).strip()
    if not value.startswith(MODEL_PREFIX):
        return None
    name = value[len(MODEL_PREFIX):]
    return name if name in SUPPORTED_MODELS else None


def magenta_home(model_name: str) -> Path:
    checkpoints_root = Path(
        os.environ.get("MAGENTA_RT_CHECKPOINTS_DIR")
        or Path.home() / "Library" / "Application Support" / "MLXtra" / "checkpoints"
    )
    return checkpoints_root / "magenta-realtime-2" / model_name


def _finite_float(value: Any, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return number if math.isfinite(number) else default


def _positive_int(value: Any, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number > 0 else default


def _nonnegative_int(value: Any, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number >= 0 else default


def generate_music_once(request: dict) -> bool:
    model_id = coerce_string(request.get("model")).strip()
    selected_model_name = model_name(model_id)
    if selected_model_name is None:
        send_json(
            {"type": "error", "message": f"Unsupported Magenta RealTime 2 model: {model_id or '(missing)'}"},
            request=request,
        )
        return False

    messages = request.get("messages", [])
    parameters = request.get("parameters", {}) or {}
    if not isinstance(parameters, dict):
        parameters = {}
    prompt = coerce_string(
        parameters.get("caption") or request.get("prompt") or last_user_prompt(messages)
    ).strip()
    if not prompt:
        send_json({"type": "error", "message": "No prompt provided for music generation"}, request=request)
        return False

    duration = min(max(_finite_float(parameters.get("duration"), 10.0), 1.0), 120.0)
    temperature = _finite_float(parameters.get("temperature"), 1.3)
    top_k = _positive_int(parameters.get("top_k"), 40)
    cfg_musiccoca = _finite_float(parameters.get("cfg_musiccoca"), 3.0)
    cfg_notes = _finite_float(parameters.get("cfg_notes"), 0.1)
    seed = _nonnegative_int(parameters.get("seed"), time.time_ns() % 2_147_483_647)
    output_dir = Path(request.get("output_dir") or Path.home() / "Music" / "MLXtra")
    model_home = magenta_home(selected_model_name)

    if not (model_home / "models" / selected_model_name).is_dir():
        send_json(
            {
                "type": "error",
                "message": (
                    f"Magenta RealTime 2 model files are missing at {model_home}. "
                    "Repair or redownload the model, then retry."
                ),
            },
            request=request,
        )
        return False

    send_model_loading(
        model_id,
        "loading_weights",
        request=request,
        detail=f"Loading {selected_model_name}",
    )
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        from magenta_rt import MagentaRT2Mlxfn, paths

        paths.set_magenta_home(model_home)
        mx.random.seed(seed)
        generator = MagentaRT2Mlxfn(
            size=selected_model_name,
            temperature=temperature,
            top_k=top_k,
            cfg_musiccoca=cfg_musiccoca,
            cfg_notes=cfg_notes,
        )

    send_json({"type": "model.loaded", "model": model_id}, request=request)
    send_generation_progress(
        model_id,
        "preparing",
        request=request,
        message="Embedding music style",
        fraction=0.05,
    )

    with contextlib.redirect_stdout(sys.stderr):
        embedding = generator.embed_style(prompt, use_mapper=True, seed=seed)
    send_generation_progress(
        model_id,
        "generating",
        request=request,
        message="Generating instrumental music",
        fraction=0.1,
    )
    with contextlib.redirect_stdout(sys.stderr):
        waveform, _ = generator.generate(style=embedding, frames=max(1, int(round(duration * 25))))

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"magenta-{selected_model_name}-{uuid.uuid4().hex}.wav"
    send_generation_progress(
        model_id,
        "finalizing",
        request=request,
        message="Writing audio file",
        fraction=0.98,
    )
    with contextlib.redirect_stdout(sys.stderr):
        waveform.write(str(output_path))

    send_json(
        {
            "type": "audio.generated",
            "path": str(output_path),
            "model": model_id,
            "sample_rate": 48000,
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
                {
                    "message": {
                        "content": (
                            f"Generated instrumental music with Magenta RealTime 2 "
                            f"({selected_model_name}). Seed: {seed}"
                        )
                    }
                }
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
        if not generate_music_once(request):
            raise SystemExit(1)
    except Exception as exc:
        error_msg = log_exception("[Magenta RealTime 2 Bridge] Unhandled error", exc)
        send_json({"type": "error", "message": error_msg}, request=request)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
