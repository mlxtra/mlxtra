#!/usr/bin/env python3
"""Shared helpers for MLXHub Python bridge scripts."""

import sys
import traceback
from typing import Callable, Optional


def log_to_stderr(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def normalize_music_model_id(model_id: str) -> str:
    """Normalize HuggingFace repo IDs to local ACE-Step checkpoint names."""
    if model_id.startswith("ACE-Step/"):
        model_id = model_id[len("ACE-Step/") :]

    if model_id.startswith("acestep-v15-turbo"):
        return "acestep-v15-turbo"

    return model_id


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
