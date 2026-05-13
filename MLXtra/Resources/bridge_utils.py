#!/usr/bin/env python3
"""Shared helpers for MLXtra Python bridge scripts."""

import sys
import traceback
from typing import Any, Callable, Optional


def log_to_stderr(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def normalize_music_model_id(model_id: str) -> str:
    """Normalize HuggingFace repo IDs to local ACE-Step checkpoint names."""
    if model_id.startswith("ACE-Step/"):
        model_id = model_id[len("ACE-Step/") :]

    if model_id.startswith("acestep-v15-turbo"):
        return "acestep-v15-turbo"

    return model_id


def coerce_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "yes", "1", "on"}:
            return True
        if lowered in {"false", "no", "0", "off", ""}:
            return False
        return default
    if isinstance(value, (int, float)):
        return value != 0
    return default


def coerce_float(value: Any, default: float) -> float:
    if value is None:
        return default
    if isinstance(value, str) and not value.strip():
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def coerce_int(value: Any, default: int) -> int:
    if value is None:
        return default
    if isinstance(value, str) and not value.strip():
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default


def coerce_string(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, str):
        return value
    return str(value)


def build_acestep_generation_inputs(
    parameters: dict[str, Any],
    *,
    prompt: str,
    lyrics: str,
    seed_default: int,
) -> tuple[int, dict[str, Any], dict[str, Any]]:
    seed = coerce_int(parameters.get("seed"), seed_default)
    thinking = coerce_bool(parameters.get("thinking"), False)
    instrumental = coerce_bool(parameters.get("instrumental"), False)

    generation_kwargs: dict[str, Any] = {
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
        generation_kwargs["bpm"] = bpm

    keyscale = coerce_string(parameters.get("keyscale")).strip()
    if keyscale:
        generation_kwargs["keyscale"] = keyscale

    timesignature = coerce_string(parameters.get("timesignature")).strip()
    if timesignature:
        generation_kwargs["timesignature"] = timesignature

    vocal_language = coerce_string(parameters.get("vocal_language")).strip()
    if vocal_language and vocal_language != "unknown":
        generation_kwargs["vocal_language"] = vocal_language

    config_kwargs = {
        "batch_size": coerce_int(parameters.get("batch_size"), 1),
        "audio_format": coerce_string(parameters.get("audio_format"), "wav") or "wav",
        "use_random_seed": False,
        "seeds": [seed],
    }

    return seed, generation_kwargs, config_kwargs


def exception_message(exc: BaseException) -> str:
    message = str(exc).strip()
    return message or exc.__class__.__name__


def log_exception(
    context: str,
    exc: BaseException,
    logger: Optional[Callable[[str], None]] = None,
) -> str:
    log = logger or log_to_stderr
    message = exception_message(exc)
    log(f"{context}: {message}")

    stack = traceback.format_exc().rstrip()
    if stack and stack != "NoneType: None":
        log(stack)

    return message
