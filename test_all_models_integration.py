#!/usr/bin/env python3
"""
Comprehensive integration tests for all MLXHub model types:
- Chat/VLM (Qwen3.5)
- Image (FLUX.2-klein)
- Audio/TTS (KugelAudio)
- Music (ACE-Step)

Tests the full end-to-end pipeline using the Python bridge subprocess.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# Setup paths
APP_BUNDLE = Path(
    "/Users/omercelik/Library/Developer/Xcode/DerivedData/MLXHub-ayxjdxuxnnlpflbgqijatrzqclph/Build/Products/Debug/MLXHub.app"
)
RESOURCES = APP_BUNDLE / "Contents/Resources"
RUNTIME = RESOURCES / "runtime/macos-arm64"
VENV_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_PYTHON = RUNTIME / "acestep-venv/bin/python"
BRIDGE_SCRIPT = RESOURCES / "python_bridge.py"
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"


class MLXHubIntegrationTest:
    """Integration tests for all MLXHub model types."""

    def __init__(self):
        self.results = []
        self.generated_files = []

    def log(self, message: str, level: str = "INFO"):
        """Log a message with timestamp."""
        timestamp = time.strftime("%H:%M:%S")
        print(f"[{timestamp}] [{level}] {message}")

    def get_bridge_env(self) -> dict:
        """Get environment variables for the Python bridge."""
        env = dict(os.environ)

        # Remove Python-related env vars that could cause conflicts
        for key in [
            "PYTHONPATH",
            "PYTHONHOME",
            "VIRTUAL_ENV",
            "CONDA_PREFIX",
            "CONDA_DEFAULT_ENV",
            "PYENV_ROOT",
            "PYENV_VERSION",
        ]:
            env.pop(key, None)

        # Set critical env vars
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
        env["HF_HUB_CACHE"] = str(Path.home() / ".cache/huggingface/hub")
        env["ACESTEP_CHECKPOINTS_DIR"] = str(
            Path.home() / "Library/Application Support/MLXHub/checkpoints"
        )

        return env

    def send_request_to_bridge(
        self, request: dict, timeout: int = 120, use_acestep: bool = False
    ) -> tuple[list[dict], bool]:
        """Send a request to the Python bridge and collect responses.
        NOTE: This starts a fresh process. For chat/VLM, use run_bridge_session()."""

        python_exe = ACESTEP_PYTHON if use_acestep else VENV_PYTHON
        script = ACESTEP_BRIDGE if use_acestep else BRIDGE_SCRIPT

        if not python_exe.exists():
            self.log(f"Python interpreter not found: {python_exe}", "ERROR")
            return [], False
        if not script.exists():
            self.log(f"Bridge script not found: {script}", "ERROR")
            return [], False

        try:
            proc = subprocess.run(
                [str(python_exe), "-u", str(script)],
                input=json.dumps(request) + "\n",
                capture_output=True,
                text=True,
                env=self.get_bridge_env(),
                timeout=timeout,
            )

            # Parse stdout
            messages = []
            for line in proc.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    messages.append(msg)
                except json.JSONDecodeError:
                    pass

            success = proc.returncode == 0 and not any(
                m.get("type") == "error" for m in messages
            )

            return messages, success

        except subprocess.TimeoutExpired:
            self.log(f"Timeout after {timeout}s", "ERROR")
            return [], False
        except Exception as e:
            self.log(f"Exception: {e}", "ERROR")
            return [], False

    def run_bridge_session(
        self, requests: list[dict], timeout: int = 300
    ) -> tuple[list[dict], bool]:
        """Run a bridge session with multiple requests (like Swift does).

        This keeps the bridge process alive and sends multiple requests,
        which is required for chat/VLM where model needs to be loaded first.
        """
        python_exe = VENV_PYTHON
        script = BRIDGE_SCRIPT

        if not python_exe.exists() or not script.exists():
            self.log(f"Bridge not found: {python_exe} or {script}", "ERROR")
            return [], False

        try:
            # Start process
            proc = subprocess.Popen(
                [str(python_exe), "-u", str(script)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.get_bridge_env(),
                bufsize=1,
            )

            all_messages = []
            start_time = time.time()

            for request in requests:
                if time.time() - start_time > timeout:
                    self.log(f"Session timeout after {timeout}s", "ERROR")
                    proc.terminate()
                    return all_messages, False

                # Send request
                proc.stdin.write(json.dumps(request) + "\n")
                proc.stdin.flush()

                # Read responses until we get a completion or timeout
                request_start = time.time()
                request_timeout = (
                    60 if request.get("type") == "chat.completions" else 300
                )

                while time.time() - request_start < request_timeout:
                    import select

                    # Check if there's output to read
                    if select.select([proc.stdout], [], [], 0.1)[0]:
                        line = proc.stdout.readline().strip()
                        if line:
                            try:
                                msg = json.loads(line)
                                all_messages.append(msg)

                                # Check for completion or error
                                if msg.get("type") in (
                                    "assistant",
                                    "chat.completion.complete",
                                    "error",
                                ):
                                    break
                                elif msg.get("type") == "model.loaded":
                                    # Model loaded, can proceed to next request
                                    break
                            except json.JSONDecodeError:
                                pass

                    # Check if process died
                    if proc.poll() is not None:
                        break

            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

            success = not any(m.get("type") == "error" for m in all_messages)
            return all_messages, success

        except Exception as e:
            self.log(f"Exception in session: {e}", "ERROR")
            return [], False

    # ==========================================================================
    # TEST 1: Setup Verification
    # ==========================================================================
    def test_setup(self) -> bool:
        """Verify all required files and directories exist."""
        self.log("\n" + "=" * 70)
        self.log("TEST 1: Setup Verification")
        self.log("=" * 70)

        checks = [
            ("App bundle", APP_BUNDLE),
            ("Main Python (venv)", VENV_PYTHON),
            ("ACE-Step Python", ACESTEP_PYTHON),
            ("Main bridge script", BRIDGE_SCRIPT),
            ("ACE-Step bridge script", ACESTEP_BRIDGE),
        ]

        all_good = True
        for name, path in checks:
            exists = path.exists()
            status = "✓" if exists else "✗"
            self.log(f"  {status} {name}: {path}")
            if not exists:
                all_good = False

        if not all_good:
            return False

        # Check model directories
        checkpoints_dir = Path.home() / "Library/Application Support/MLXHub/checkpoints"
        self.log(f"\n  Checkpoints directory: {checkpoints_dir}")

        if not checkpoints_dir.exists():
            self.log("  ✗ Checkpoints directory does not exist", "ERROR")
            return False

        # List contents
        try:
            for item in sorted(checkpoints_dir.iterdir()):
                if item.is_dir():
                    self.log(f"  ✓ {item.name}/")
        except Exception as e:
            self.log(f"  Warning: Could not list checkpoints: {e}", "WARNING")

        return True

    # ==========================================================================
    # TEST 2: Model ID Normalization
    # ==========================================================================
    def test_model_normalization(self) -> bool:
        """Test that HuggingFace repo IDs are normalized to local names."""
        self.log("\n" + "=" * 70)
        self.log("TEST 2: Model ID Normalization")
        self.log("=" * 70)

        # Read normalization function from acestep_bridge.py
        try:
            bridge_code = ACESTEP_BRIDGE.read_text()
            namespace = {}
            exec(bridge_code.split("def generate_music_once")[0], namespace)
            normalize_fn = namespace.get("_normalize_music_model_id")

            if not normalize_fn:
                self.log("Could not extract normalization function", "ERROR")
                return False

            test_cases = [
                ("ACE-Step/acestep-v15-turbo-continuous", "acestep-v15-turbo"),
                ("ACE-Step/acestep-v15-turbo-shift3", "acestep-v15-turbo"),
                ("acestep-v15-turbo", "acestep-v15-turbo"),
                ("ACE-Step/acestep-v15-turbo-rl", "acestep-v15-turbo"),
            ]

            all_passed = True
            for input_id, expected in test_cases:
                result = normalize_fn(input_id)
                passed = result == expected
                status = "✓" if passed else "✗"
                self.log(f"  {status} '{input_id}' → '{result}'")
                if not passed:
                    all_passed = False

            return all_passed

        except Exception as e:
            self.log(f"Error: {e}", "ERROR")
            return False

    # ==========================================================================
    # TEST 3: Chat/Completion (VLM)
    # ==========================================================================
    def test_chat_completion(self) -> bool:
        """Test chat completion with a simple model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 3: Chat/Completion (VLM)")
        self.log("=" * 70)

        model_id = "mlx-community/Qwen3.5-9B-MLX-4bit"

        # Check if model is downloaded (in HuggingFace cache)
        model_path = (
            Path.home()
            / ".cache/huggingface/hub/models--mlx-community--Qwen3.5-9B-MLX-4bit"
        )

        if not model_path.exists():
            self.log(f"⚠ SKIPPED: Model not downloaded at {model_path}")
            self.log(f"   Run the app to download the model first, or run:")
            self.log(f"   mlx-lm.server --model {model_id}")
            return True  # Skip but don't fail

        self.log(f"Found model at: {model_path}")

        # Use persistent session for chat (init + chat in same process)
        requests = [
            # Step 1: Initialize model
            {"type": "init", "model_id": model_id, "backend": "vlm"},
            # Step 2: Send chat request
            {
                "type": "chat.completions",
                "model": model_id,
                "messages": [
                    {"role": "user", "content": "What is 2+2? Answer in one word."}
                ],
                "temperature": 0.7,
                "max_tokens": 10,
            },
        ]

        self.log("Running bridge session (init + chat)...")
        messages, success = self.run_bridge_session(requests, timeout=600)

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Session failed", "ERROR")
            return False

        # Check for completion
        completions = [
            m for m in messages if m.get("type") == "chat.completion.complete"
        ]
        if completions:
            choices = completions[0].get("choices", [])
            if choices and choices[0].get("message", {}).get("content"):
                content = choices[0]["message"]["content"]
                self.log(f"✓ SUCCESS: Got response: '{content[:50]}...'")
                return True

        # Also check for streaming chunks
        chunks = [m for m in messages if m.get("type") == "chat.completion.chunk"]
        if chunks:
            # Combine chunk content
            full_content = ""
            for chunk in chunks:
                choices = chunk.get("choices", [])
                if choices:
                    delta = choices[0].get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        full_content += content
            if full_content:
                self.log(f"✓ SUCCESS: Got streaming response: '{full_content[:50]}...'")
                return True

        self.log("✗ FAILED: No assistant response received", "ERROR")
        self.log(f"  Messages received: {[m.get('type') for m in messages]}")
        return False

        # Wait for model.loaded
        loaded = any(
            m.get("type") in ("model.loaded", "model.initialized") for m in messages
        )
        if not loaded:
            self.log("✗ FAILED: model.loaded not received after init", "ERROR")
            return False

        self.log("✓ Model initialized and loaded")

        # Step 2: Send chat request
        self.log("Step 2: Send chat request...")
        request = {
            "type": "chat.completions",
            "model": model_id,
            "messages": [
                {"role": "user", "content": "What is 2+2? Answer in one word."}
            ],
            "temperature": 0.7,
            "max_tokens": 10,
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")

        messages, success = self.send_request_to_bridge(request, timeout=60)

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Timeout waiting for response", "ERROR")
            return False

        # Check for assistant response
        assistants = [m for m in messages if m.get("type") == "assistant"]
        if assistants:
            content = assistants[0].get("content", "")
            self.log(f"✓ SUCCESS: Got response: '{content[:50]}...'")
            return True

        self.log("✗ FAILED: No assistant response received", "ERROR")
        return False

    # ==========================================================================
    # TEST 4: Image Generation (FLUX)
    # ==========================================================================
    def test_image_generation(self) -> bool:
        """Test image generation with FLUX."""
        self.log("\n" + "=" * 70)
        self.log("TEST 4: Image Generation (FLUX)")
        self.log("=" * 70)

        request = {
            "type": "image.generate",
            "model": "black-forest-labs/FLUX.2-klein-4B",
            "prompt": "A simple red circle on white background",
            "width": 512,
            "height": 512,
            "steps": 4,
            "seed": 42,
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating image (this may take 30-60s)...")

        messages, success = self.send_request_to_bridge(request, timeout=120)

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Generation failed", "ERROR")
            return False

        # Check for generated image
        images = [m for m in messages if m.get("type") == "image.generated"]
        if images:
            path = images[0].get("path")
            self.generated_files.append(path)
            file_size = Path(path).stat().st_size / 1024 if Path(path).exists() else 0
            self.log(f"✓ SUCCESS: Image generated at {path}")
            self.log(f"  Size: {file_size:.1f} KB")
            return True

        self.log("✗ FAILED: No image.generated message received", "ERROR")
        return False

    # ==========================================================================
    # TEST 5: Audio/Speech (TTS)
    # ==========================================================================
    def test_audio_speech(self) -> bool:
        """Test text-to-speech with KugelAudio."""
        self.log("\n" + "=" * 70)
        self.log("TEST 5: Audio/Speech (TTS)")
        self.log("=" * 70)

        request = {
            "type": "audio.speech",
            "model": "kugelaudio/kugelaudio-0-open",
            "input": "Hello world. This is a test.",
            "voice": "default",
            "ddpm_steps": 10,
            "cfg_scale": 3.0,
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating speech (this may take 20-40s)...")

        messages, success = self.send_request_to_bridge(request, timeout=90)

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Generation failed", "ERROR")
            return False

        # Check for generated audio
        audio_msgs = [m for m in messages if m.get("type") == "audio.generated"]
        if audio_msgs:
            path = audio_msgs[0].get("path")
            self.generated_files.append(path)
            sample_rate = audio_msgs[0].get("sample_rate", "unknown")
            self.log(f"✓ SUCCESS: Audio generated at {path}")
            self.log(f"  Sample rate: {sample_rate} Hz")
            return True

        self.log("✗ FAILED: No audio.generated message received", "ERROR")
        return False

    # ==========================================================================
    # TEST 6: Music Generation (ACE-Step)
    # ==========================================================================
    def test_music_generation(self) -> bool:
        """Test music generation with ACE-Step."""
        self.log("\n" + "=" * 70)
        self.log("TEST 6: Music Generation (ACE-Step)")
        self.log("=" * 70)

        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "messages": [{"role": "user", "content": "upbeat electronic dance music"}],
            "parameters": {
                "caption": "upbeat electronic dance music",
                "duration": 10,
                "inference_steps": 4,
                "seed": 42,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating music via acestep_bridge...")

        messages, success = self.send_request_to_bridge(
            request, timeout=120, use_acestep=True
        )

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Generation failed", "ERROR")
            return False

        # Check for generated audio
        audio_msgs = [m for m in messages if m.get("type") == "audio.generated"]
        if audio_msgs:
            path = audio_msgs[0].get("path")
            self.generated_files.append(path)
            file_size = (
                Path(path).stat().st_size / (1024 * 1024) if Path(path).exists() else 0
            )
            self.log(f"✓ SUCCESS: Music generated at {path}")
            self.log(f"  File size: {file_size:.2f} MB")
            return True

        self.log("✗ FAILED: No audio.generated message received", "ERROR")
        return False

    # ==========================================================================
    # Run All Tests
    # ==========================================================================
    def run(self) -> bool:
        """Run all integration tests."""
        self.log("\n" + "=" * 70)
        self.log("MLXHub Integration Test Suite")
        self.log("=" * 70)
        self.log(f"Python: {sys.version.split()[0]}")
        self.log(
            f"ACESTEP_CHECKPOINTS_DIR: {self.get_bridge_env()['ACESTEP_CHECKPOINTS_DIR']}"
        )

        tests = [
            ("Setup Verification", self.test_setup, False),
            ("Model Normalization", self.test_model_normalization, False),
            ("Chat/Completion (VLM)", self.test_chat_completion, True),
            ("Image Generation (FLUX)", self.test_image_generation, True),
            ("Audio/Speech (TTS)", self.test_audio_speech, True),
            ("Music Generation (ACE-Step)", self.test_music_generation, True),
        ]

        results = []
        for name, test_func, requires_model in tests:
            try:
                passed = test_func()
                results.append((name, passed))
            except Exception as e:
                self.log(f"EXCEPTION in {name}: {e}", "ERROR")
                import traceback

                traceback.print_exc()
                results.append((name, False))

        # Summary
        self.log("\n" + "=" * 70)
        self.log("TEST SUMMARY")
        self.log("=" * 70)

        for name, passed in results:
            status = "✓ PASS" if passed else "✗ FAIL"
            self.log(f"  {status}: {name}")

        all_passed = all(passed for _, passed in results)
        self.log(
            "\n" + ("✓ All tests passed!" if all_passed else "✗ Some tests failed!")
        )

        # List generated files
        if self.generated_files:
            self.log("\nGenerated files:")
            for f in self.generated_files:
                self.log(f"  - {f}")

        return all_passed


if __name__ == "__main__":
    test = MLXHubIntegrationTest()
    success = test.run()
    sys.exit(0 if success else 1)
