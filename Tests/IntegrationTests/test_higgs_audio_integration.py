#!/usr/bin/env python3
"""Cached-model smoke test for Higgs Audio v3 speech generation."""

import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Optional

from runtime_layout import resolve_base_runtime

REPO_ROOT = Path(__file__).resolve().parents[2]
MODEL_ID = "bosonai/higgs-audio-v3-tts-4b"
HF_CACHE = Path.home() / ".cache/huggingface/hub"
APP_SUPPORT = Path.home() / "Library/Application Support/MLXtra"
REQUIRE_ALL_MODELS = (
    os.environ.get("MLXTRA_REQUIRE_ALL_MODELS") == "1"
    or "--strict" in sys.argv[1:]
)


def _derived_data_app_candidates() -> list[Path]:
    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    return list(derived_data.glob("MLXtra-*/Build/Products/Debug/MLXtra.app"))


def _newest_existing_app() -> Optional[Path]:
    candidates = [path for path in _derived_data_app_candidates() if path.exists()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def _build_app() -> None:
    subprocess.run(
        [
            "xcodebuild",
            "-project",
            "MLXtra.xcodeproj",
            "-scheme",
            "MLXtra",
            "-configuration",
            "Debug",
            "build",
        ],
        cwd=REPO_ROOT,
        check=True,
    )


def resolve_app_bundle() -> Path:
    override = os.environ.get("MLXTRA_APP_BUNDLE")
    if override:
        return Path(override)

    if os.environ.get("MLXTRA_BUILD_APP") == "1":
        _build_app()

    app_bundle = _newest_existing_app()
    if app_bundle:
        return app_bundle

    _build_app()
    app_bundle = _newest_existing_app()
    if app_bundle:
        return app_bundle
    raise FileNotFoundError("Could not find or build MLXtra.app")


def path_has_content(path: Path) -> bool:
    try:
        return path.resolve(strict=True).is_file() and path.stat().st_size > 0
    except OSError:
        return False


def snapshot_is_complete() -> bool:
    snapshots_dir = HF_CACHE / f"models--{MODEL_ID.replace('/', '--')}" / "snapshots"
    if not snapshots_dir.exists():
        return False

    for snapshot in snapshots_dir.iterdir():
        if not snapshot.is_dir():
            continue
        if (snapshot / ".mlxtra_snapshot_in_progress").exists():
            continue
        if not any(
            path_has_content(snapshot / name)
            for name in ("config.json", "model_index.json", "tokenizer.json")
        ):
            continue
        if any(
            path_has_content(path)
            for path in snapshot.rglob("*.safetensors")
        ):
            return True
    return False


def bridge_environment(runtime: Path) -> dict[str, str]:
    env = dict(os.environ)
    for key in (
        "PYTHONPATH",
        "PYTHONHOME",
        "VIRTUAL_ENV",
        "CONDA_PREFIX",
        "CONDA_DEFAULT_ENV",
        "PYENV_ROOT",
        "PYENV_VERSION",
    ):
        env.pop(key, None)

    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONHOME"] = str(runtime / "python/Frameworks/Versions/3.12")
    env["MLXTRA_RUNTIME_DIR"] = str(runtime)
    env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
    env["HF_HUB_CACHE"] = str(HF_CACHE)
    env["HF_HUB_OFFLINE"] = "1"
    env["TRANSFORMERS_OFFLINE"] = "1"
    env["MTL_DEBUG_LAYER"] = "0"
    env["MTL_SHADER_VALIDATION"] = "0"
    return env


def validate_wav(path: Path) -> bool:
    if not path_has_content(path):
        print(f"ERROR: Generated WAV is missing or empty: {path}")
        return False

    with wave.open(str(path), "rb") as audio:
        sample_rate = audio.getframerate()
        channels = audio.getnchannels()
        frames = audio.getnframes()

    duration = frames / sample_rate if sample_rate else 0
    if sample_rate != 24000 or channels != 1 or duration <= 0:
        print(
            "ERROR: Unexpected WAV format: "
            f"{sample_rate} Hz, {channels} channel(s), {duration:.2f}s"
        )
        return False

    print(f"PASS: Generated {path} ({duration:.2f}s, {sample_rate} Hz, mono)")
    return True


def main() -> bool:
    if not snapshot_is_complete():
        message = "Higgs Audio v3 snapshot is missing or incomplete"
        if REQUIRE_ALL_MODELS:
            print(f"ERROR: {message}")
            return False
        print(f"SKIP: {message}; downloads remain disabled")
        return True

    app_bundle = resolve_app_bundle()
    resources = app_bundle / "Contents/Resources"
    runtime = resolve_base_runtime(resources, APP_SUPPORT)
    python = runtime / "venv/bin/python"
    bridge = resources / "python_bridge.py"
    output_dir = APP_SUPPORT / "GeneratedSpeech"
    output_dir.mkdir(parents=True, exist_ok=True)

    request_id = f"higgs-smoke-{int(time.time())}"
    request = {
        "type": "audio.speech",
        "model": MODEL_ID,
        "request_id": request_id,
        "messages": [{"role": "user", "content": "A short story begins here."}],
        "output_dir": str(output_dir),
        "parameters": {
            "voice": "female_story",
            "emotion": "neutral",
            "max_new_tokens": 256,
            "temperature": 1.0,
            "top_p": 0.9,
            "top_k": 50,
            "seed": 42,
            "runtimeOptions": {
                "audio": {
                    "adapter": "higgs-audio-v3",
                    "defaultVoice": "default",
                }
            },
        },
    }

    print(f"Running Higgs Audio v3 smoke test with {python}")
    try:
        result = subprocess.run(
            [str(python), "-u", str(bridge)],
            input=json.dumps(request) + "\n",
            capture_output=True,
            text=True,
            env=bridge_environment(runtime),
            timeout=600,
        )
    except subprocess.TimeoutExpired:
        print("ERROR: Higgs Audio v3 smoke test timed out after 600 seconds")
        return False

    messages = []
    for line in result.stdout.splitlines():
        try:
            messages.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    errors = [message for message in messages if message.get("type") == "error"]
    if errors:
        print(f"ERROR: {errors[-1].get('message')}")
        return False
    if result.returncode != 0:
        print(f"ERROR: Bridge exited with code {result.returncode}")
        for line in result.stderr.splitlines()[-20:]:
            print(f"  {line}")
        return False

    generated = [
        message
        for message in messages
        if message.get("type") == "audio.generated"
        and message.get("request_id") == request_id
    ]
    completed = [
        message
        for message in messages
        if message.get("type") == "chat.completion.complete"
        and message.get("request_id") == request_id
    ]
    if not generated or not completed:
        print("ERROR: Bridge did not emit audio.generated and completion messages")
        return False

    return validate_wav(Path(generated[-1]["path"]))


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
