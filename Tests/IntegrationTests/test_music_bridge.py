#!/usr/bin/env python3
"""
Test music generation exactly like Swift does it.
This runs the python_bridge.py with the same environment variables Swift sets.
"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

from runtime_layout import (
    prepared_music_runtime,
    resolve_base_runtime,
    resolve_music_runtime,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


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


APP_BUNDLE = resolve_app_bundle()
RESOURCES = APP_BUNDLE / "Contents/Resources"
APP_SUPPORT = Path.home() / "Library/Application Support/MLXtra"
RUNTIME = resolve_base_runtime(RESOURCES, APP_SUPPORT)
MUSIC_RUNTIME = resolve_music_runtime(RUNTIME, RESOURCES)
VENV_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_PYTHON = MUSIC_RUNTIME / "acestep-venv/bin/python"
BRIDGE_SCRIPT = RESOURCES / "python_bridge.py"
ACESTEP_CHECKPOINTS_DIR = APP_SUPPORT / "checkpoints"
REQUIRE_ALL_MODELS = (
    os.environ.get("MLXTRA_REQUIRE_ALL_MODELS") == "1"
    or "--strict" in sys.argv[1:]
)


def get_env():
    """Get environment variables matching Swift's VLMExecutor.setupEnvironment()"""
    env = dict(os.environ)

    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env.pop("VIRTUAL_ENV", None)
    env.pop("CONDA_PREFIX", None)
    env.pop("CONDA_DEFAULT_ENV", None)
    env.pop("PYENV_ROOT", None)
    env.pop("PYENV_VERSION", None)

    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONHOME"] = str(RUNTIME / "python/Frameworks/Versions/3.12")
    env["MLXTRA_RUNTIME_DIR"] = str(RUNTIME)
    env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
    env["HF_HUB_CACHE"] = str(Path.home() / ".cache/huggingface/hub")
    env["ACESTEP_CHECKPOINTS_DIR"] = str(ACESTEP_CHECKPOINTS_DIR)
    env["ACESTEP_PYTHON"] = str(ACESTEP_PYTHON)
    env["MTL_DEBUG_LAYER"] = "0"
    env["MTL_SHADER_VALIDATION"] = "0"

    return env


def music_model_is_complete() -> bool:
    required_files = (
        ACESTEP_CHECKPOINTS_DIR / "acestep-v15-turbo/model.safetensors",
        ACESTEP_CHECKPOINTS_DIR / "vae/diffusion_pytorch_model.safetensors",
        ACESTEP_CHECKPOINTS_DIR / "Qwen3-Embedding-0.6B/model.safetensors",
        ACESTEP_CHECKPOINTS_DIR / "acestep-5Hz-lm-1.7B/model.safetensors",
    )
    return all(path.is_file() and path.stat().st_size > 0 for path in required_files)


class BridgeTest:
    def __init__(self):
        self.proc = None
        self.stdout_lines = []
        self.stderr_lines = []
        self.lock = threading.Lock()

    def read_stdout(self):
        """Read stdout in a thread."""
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            with self.lock:
                self.stdout_lines.append(line)
            print(f"  [STDOUT] {line[:200]}")

    def read_stderr(self):
        """Read stderr in a thread."""
        for line in self.proc.stderr:
            line = line.rstrip("\n")
            with self.lock:
                self.stderr_lines.append(line)
            if (
                "error" in line.lower()
                or "exception" in line.lower()
                or "failed" in line.lower()
            ):
                print(f"  [STDERR] {line[:200]}")

    def wait_for_message(self, msg_type, timeout=30):
        """Wait for a specific message type."""
        start = time.time()
        while time.time() - start < timeout:
            with self.lock:
                for line in self.stdout_lines:
                    try:
                        msg = json.loads(line)
                        if msg.get("type") == msg_type:
                            return msg
                    except json.JSONDecodeError:
                        pass
            time.sleep(0.1)
        return None

    def run(self):
        """Test the Python bridge exactly like Swift does."""
        print("=" * 70)
        print("TEST: Music Generation via Python Bridge (Swift-compatible)")
        print("=" * 70)

        print(f"\nPython interpreter: {VENV_PYTHON}")
        print(f"Bridge script: {BRIDGE_SCRIPT}")
        print(
            f"ACESTEP_CHECKPOINTS_DIR: {Path.home() / 'Library/Application Support/MLXtra/checkpoints'}"
        )

        if not VENV_PYTHON.exists():
            print(f"ERROR: Python not found at {VENV_PYTHON}")
            return False
        if not BRIDGE_SCRIPT.exists():
            print(f"ERROR: Bridge script not found at {BRIDGE_SCRIPT}")
            return False

        print("\n✓ Found Python interpreter and bridge script")

        env = get_env()
        print(f"\nStarting bridge process...")

        try:
            self.proc = subprocess.Popen(
                [str(VENV_PYTHON), "-u", str(BRIDGE_SCRIPT)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                bufsize=1,
            )

            print(f"✓ Bridge process started (PID: {self.proc.pid})")

            stdout_thread = threading.Thread(target=self.read_stdout, daemon=True)
            stderr_thread = threading.Thread(target=self.read_stderr, daemon=True)
            stdout_thread.start()
            stderr_thread.start()

            print("\nWaiting for system.ready...")
            msg = self.wait_for_message("system.ready", timeout=10)
            if not msg:
                print("ERROR: system.ready not received within timeout")
                return False
            print("✓ Bridge is ready")

            print("\n--- Step 1: Initialize model ---")
            init_request = {
                "type": "init",
                "model_id": "ACE-Step/acestep-v15-turbo-continuous",
                "backend": "music",
            }
            print(f"Sending: {json.dumps(init_request)}")
            self.proc.stdin.write(json.dumps(init_request) + "\n")
            self.proc.stdin.flush()

            msg = self.wait_for_message("model.initialized", timeout=10)
            if not msg:
                print("ERROR: model.initialized not received")
                return False
            print(f"✓ Model initialized: {msg.get('model')}")
            print("  (Lazy init - actual loading happens on first generate)")

            if not music_model_is_complete():
                if REQUIRE_ALL_MODELS:
                    print("ERROR: ACE-Step checkpoints are missing or incomplete")
                    return False
                print("\n↷ SKIP: ACE-Step checkpoints are missing or incomplete")
                return True

            print("\n--- Step 2: Generate music ---")
            generate_request = {
                "type": "music.generate",
                "messages": [
                    {"role": "user", "content": "upbeat electronic dance music"}
                ],
                "parameters": {
                    "caption": "upbeat electronic dance music",
                    "duration": 10,
                    "inference_steps": 4,
                    "seed": 42,
                },
            }
            print(f"Sending: {json.dumps(generate_request)}")
            self.proc.stdin.write(json.dumps(generate_request) + "\n")
            self.proc.stdin.flush()

            print("\nWaiting for generation to complete...")
            start = time.time()
            timeout = 120  # 2 minutes
            seen_stdout_lines = 0
            generated_audio_path = None

            while time.time() - start < timeout:
                with self.lock:
                    lines = self.stdout_lines[seen_stdout_lines:]
                    seen_stdout_lines = len(self.stdout_lines)

                for line in lines:
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    msg_type = msg.get("type")
                    if msg_type == "model.loading":
                        print(f"  → Model loading: {msg.get('status')}")
                    elif msg_type == "model.loaded":
                        print(f"  → Model loaded: {msg.get('model')}")
                    elif msg_type == "audio.generated":
                        generated_audio_path = msg.get("path")
                        print(f"  → Audio generated: {generated_audio_path}")
                    elif msg_type == "chat.completion.complete":
                        print("\n✓ SUCCESS: Music generation completed!")
                        if generated_audio_path:
                            print(f"  Output: {generated_audio_path}")
                        return True
                    elif msg_type == "error":
                        print(f"\n✗ FAILED: {msg.get('message')}")
                        return False

                if self.proc.poll() is not None:
                    print(f"Process exited with code {self.proc.poll()}")
                    break

                time.sleep(0.1)

            print("\n? TIMEOUT: Generation did not complete within timeout")
            return False

        except Exception as e:
            print(f"EXCEPTION: {e}")
            import traceback

            traceback.print_exc()
            return False

        finally:
            print("\n--- Cleanup ---")
            if self.proc:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()

            if self.stderr_lines:
                print("\n--- Collected stderr ---")
                for line in self.stderr_lines[-30:]:  # Last 30 lines
                    if line.strip():
                        print(f"  {line}")


if __name__ == "__main__":
    with prepared_music_runtime(RUNTIME, MUSIC_RUNTIME):
        test = BridgeTest()
        success = test.run()
    sys.exit(0 if success else 1)
