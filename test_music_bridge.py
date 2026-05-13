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

# Paths
APP_BUNDLE = Path(
    "/Users/omercelik/Library/Developer/Xcode/DerivedData/MLXtra-ayxjdxuxnnlpflbgqijatrzqclph/Build/Products/Debug/MLXtra.app"
)
RESOURCES = APP_BUNDLE / "Contents/Resources"
RUNTIME = RESOURCES / "runtime/macos-arm64"
VENV_PYTHON = RUNTIME / "acestep-venv/bin/python"
BRIDGE_SCRIPT = RESOURCES / "python_bridge.py"


def get_env():
    """Get environment variables matching Swift's VLMExecutor.setupEnvironment()"""
    env = dict(os.environ)

    # Remove Python-related env vars that could cause conflicts
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env.pop("VIRTUAL_ENV", None)
    env.pop("CONDA_PREFIX", None)
    env.pop("CONDA_DEFAULT_ENV", None)
    env.pop("PYENV_ROOT", None)
    env.pop("PYENV_VERSION", None)

    # Set critical env vars
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
    env["HF_HUB_CACHE"] = str(Path.home() / ".cache/huggingface/hub")
    env["ACESTEP_CHECKPOINTS_DIR"] = str(
        Path.home() / "Library/Application Support/MLXtra/checkpoints"
    )

    return env


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

        # Start the bridge process
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

            # Start reader threads
            stdout_thread = threading.Thread(target=self.read_stdout, daemon=True)
            stderr_thread = threading.Thread(target=self.read_stderr, daemon=True)
            stdout_thread.start()
            stderr_thread.start()

            # Wait for system.ready
            print("\nWaiting for system.ready...")
            msg = self.wait_for_message("system.ready", timeout=10)
            if not msg:
                print("ERROR: system.ready not received within timeout")
                return False
            print("✓ Bridge is ready")

            # Step 1: Initialize music model
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

            # Step 2: Generate music
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

            # Wait for completion or error
            print("\nWaiting for generation to complete...")
            start = time.time()
            timeout = 120  # 2 minutes

            while time.time() - start < timeout:
                msg = self.wait_for_message("*", timeout=1)  # Poll for any message

                # Check stdout for messages
                with self.lock:
                    for line in self.stdout_lines:
                        try:
                            msg = json.loads(line)
                            msg_type = msg.get("type")

                            if msg_type == "model.loading":
                                print(f"  → Model loading: {msg.get('status')}")
                            elif msg_type == "model.loaded":
                                print(f"  → Model loaded: {msg.get('model')}")
                            elif msg_type == "error":
                                print(f"\n✗ FAILED: {msg.get('message')}")
                                return False
                            elif msg_type == "assistant":
                                print(f"\n✓ SUCCESS: Music generation completed!")
                                print(f"  Output: {msg.get('content', '')[:200]}...")
                                return True
                        except json.JSONDecodeError:
                            pass

                # Check if process is still running
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

            # Print any stderr
            if self.stderr_lines:
                print("\n--- Collected stderr ---")
                for line in self.stderr_lines[-30:]:  # Last 30 lines
                    if line.strip():
                        print(f"  {line}")


if __name__ == "__main__":
    test = BridgeTest()
    success = test.run()
    sys.exit(0 if success else 1)
