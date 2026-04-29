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
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Optional

# Setup paths
DEFAULT_APP_BUNDLE = Path(
    "/Users/omercelik/Library/Developer/Xcode/DerivedData/MLXHub-ayxjdxuxnnlpflbgqijatrzqclph/Build/Products/Debug/MLXHub.app"
)


def resolve_app_bundle() -> Path:
    override = os.environ.get("MLXHUB_APP_BUNDLE")
    if override:
        return Path(override)

    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    candidates = list(derived_data.glob("MLXHub-*/Build/Products/Debug/MLXHub.app"))
    if candidates:
        return max(candidates, key=lambda path: path.stat().st_mtime)

    return DEFAULT_APP_BUNDLE


APP_BUNDLE = resolve_app_bundle()
RESOURCES = APP_BUNDLE / "Contents/Resources"
RUNTIME = RESOURCES / "runtime/macos-arm64"
VENV_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_PYTHON = RUNTIME / "acestep-venv/bin/python"
BRIDGE_SCRIPT = RESOURCES / "python_bridge.py"
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"
APP_SUPPORT = Path.home() / "Library/Application Support/MLXHub"
GENERATED_IMAGES_DIR = APP_SUPPORT / "GeneratedImages"
GENERATED_SPEECH_DIR = APP_SUPPORT / "GeneratedSpeech"
GENERATED_MUSIC_DIR = APP_SUPPORT / "GeneratedMusic"


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
        env["PYTHONHOME"] = str(
            APP_BUNDLE
            / "Contents/Resources/runtime/macos-arm64/python/Frameworks/Versions/3.12"
        )
        env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
        env["HF_HUB_CACHE"] = str(Path.home() / ".cache/huggingface/hub")
        env["ACESTEP_CHECKPOINTS_DIR"] = str(
            Path.home() / "Library/Application Support/MLXHub/checkpoints"
        )
        env["MTL_DEBUG_LAYER"] = "0"
        env["MTL_SHADER_VALIDATION"] = "0"

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

            messages = []
            non_json_stdout = []
            for line in proc.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    messages.append(msg)
                except json.JSONDecodeError:
                    non_json_stdout.append(line)

            for line in non_json_stdout[:5]:
                self.log(f"  [non-json stdout] {line[:150]}", "ERROR")

            if proc.returncode != 0:
                self.log(f"Process exited with code {proc.returncode}", "ERROR")
                for line in proc.stderr.splitlines()[-20:]:
                    self.log(f"  [stderr] {line[:150]}", "ERROR")

            success = (
                proc.returncode == 0
                and not non_json_stdout
                and not any(m.get("type") == "error" for m in messages)
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

    def route_errors(self, messages: list[dict]) -> list[dict]:
        return [m for m in messages if m.get("type") == "error"]

    def require_no_error(self, messages: list[dict]) -> bool:
        errors = self.route_errors(messages)
        if errors:
            self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            return False
        return True

    def require_completion(self, messages: list[dict], request_id: str) -> bool:
        completions = [
            m
            for m in messages
            if m.get("type") == "chat.completion.complete"
            and m.get("request_id") == request_id
        ]
        if not completions:
            self.log("✗ FAILED: No chat.completion.complete message received", "ERROR")
            return False
        return True

    def require_message(
        self, messages: list[dict], message_type: str, request_id: str
    ) -> Optional[dict]:
        matches = [
            m
            for m in messages
            if m.get("type") == message_type and m.get("request_id") == request_id
        ]
        if not matches:
            self.log(f"✗ FAILED: No {message_type} message received", "ERROR")
            return None
        return matches[0]

    def validate_png(self, path: str, expected_width: int, expected_height: int) -> bool:
        image_path = Path(path)
        if not image_path.exists():
            self.log(f"✗ FAILED: Image file does not exist: {image_path}", "ERROR")
            return False

        if image_path.stat().st_size <= 0:
            self.log(f"✗ FAILED: Image file is empty: {image_path}", "ERROR")
            return False

        with image_path.open("rb") as file:
            header = file.read(24)

        if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
            self.log(f"✗ FAILED: Image is not a PNG: {image_path}", "ERROR")
            return False

        width, height = struct.unpack(">II", header[16:24])
        if (width, height) != (expected_width, expected_height):
            self.log(
                f"✗ FAILED: PNG dimensions are {width}x{height}, expected {expected_width}x{expected_height}",
                "ERROR",
            )
            return False

        file_size = image_path.stat().st_size / 1024
        self.log(f"✓ PNG validated: {image_path} ({width}x{height}, {file_size:.1f} KB)")
        return True

    def validate_wav(
        self, path: str, minimum_duration: float = 0.1, expected_sample_rate: Optional[int] = None
    ) -> bool:
        audio_path = Path(path)
        if not audio_path.exists():
            self.log(f"✗ FAILED: Audio file does not exist: {audio_path}", "ERROR")
            return False

        if audio_path.stat().st_size <= 0:
            self.log(f"✗ FAILED: Audio file is empty: {audio_path}", "ERROR")
            return False

        try:
            with wave.open(str(audio_path), "rb") as wav_file:
                channels = wav_file.getnchannels()
                sample_rate = wav_file.getframerate()
                frames = wav_file.getnframes()
        except wave.Error as e:
            self.log(f"✗ FAILED: Invalid WAV file: {e}", "ERROR")
            return False

        if channels <= 0 or frames <= 0 or sample_rate <= 0:
            self.log(
                f"✗ FAILED: Invalid WAV metadata channels={channels}, frames={frames}, sample_rate={sample_rate}",
                "ERROR",
            )
            return False

        duration = frames / sample_rate
        if duration < minimum_duration:
            self.log(
                f"✗ FAILED: WAV duration {duration:.2f}s is shorter than {minimum_duration:.2f}s",
                "ERROR",
            )
            return False

        if expected_sample_rate is not None and sample_rate != expected_sample_rate:
            self.log(
                f"✗ FAILED: WAV sample rate {sample_rate}, expected {expected_sample_rate}",
                "ERROR",
            )
            return False

        file_size = audio_path.stat().st_size / (1024 * 1024)
        self.log(
            f"✓ WAV validated: {audio_path} ({sample_rate} Hz, {duration:.2f}s, {file_size:.2f} MB)"
        )
        return True

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

        for output_dir in (GENERATED_IMAGES_DIR, GENERATED_SPEECH_DIR, GENERATED_MUSIC_DIR):
            output_dir.mkdir(parents=True, exist_ok=True)
            self.log(f"  ✓ Output directory: {output_dir}")

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
            namespace = {"__file__": str(ACESTEP_BRIDGE)}
            if str(RESOURCES) not in sys.path:
                sys.path.insert(0, str(RESOURCES))
            exec(bridge_code.split("def generate_music_once")[0], namespace)
            normalize_fn = namespace.get("normalize_music_model_id")

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

        request_id = "integration-image-generate"
        request = {
            "type": "image.generate",
            "model": "black-forest-labs/FLUX.2-klein-4B",
            "request_id": request_id,
            "messages": [
                {"role": "user", "content": "A simple red circle on white background"}
            ],
            "output_dir": str(GENERATED_IMAGES_DIR),
            "parameters": {
                "width": 512,
                "height": 512,
                "steps": 4,
                "seed": 42,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating image (this may take 30-60s)...")

        messages, success = self.send_request_to_bridge(request, timeout=120)

        if not success or not self.require_no_error(messages):
            return False

        image_message = self.require_message(messages, "image.generated", request_id)
        if not image_message or not self.require_completion(messages, request_id):
            return False

        path = image_message.get("path")
        if not path:
            self.log("✗ FAILED: image.generated did not include a path", "ERROR")
            return False

        self.generated_files.append(path)
        return self.validate_png(path, expected_width=512, expected_height=512)

    def test_image_missing_prompt_returns_error(self) -> bool:
        """Invalid image generation request returns JSON error without loading a model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 5: Image Missing Prompt Error")
        self.log("=" * 70)

        request_id = "integration-image-missing-prompt"
        request = {
            "type": "image.generate",
            "model": "black-forest-labs/FLUX.2-klein-4B",
            "request_id": request_id,
            "messages": [{"role": "user", "content": ""}],
            "output_dir": str(GENERATED_IMAGES_DIR),
        }

        messages, _ = self.send_request_to_bridge(request, timeout=30)
        errors = [
            m
            for m in messages
            if m.get("type") == "error" and m.get("request_id") == request_id
        ]
        if not errors:
            self.log("✗ FAILED: Missing image prompt did not return an error", "ERROR")
            return False

        self.log(f"✓ Error returned: {errors[0].get('message')}")
        return "No prompt provided" in errors[0].get("message", "")

    # ==========================================================================
    # TEST 5: Audio/Speech (TTS)
    # ==========================================================================
    def test_audio_speech(self) -> bool:
        """Test text-to-speech with KugelAudio."""
        self.log("\n" + "=" * 70)
        self.log("TEST 6: Audio/Speech (TTS)")
        self.log("=" * 70)

        request_id = "integration-audio-speech"
        request = {
            "type": "audio.speech",
            "model": "kugelaudio/kugelaudio-0-open",
            "request_id": request_id,
            "messages": [{"role": "user", "content": "Hello world. This is a test."}],
            "output_dir": str(GENERATED_SPEECH_DIR),
            "parameters": {
                "voice": "default",
                "ddpm_steps": 4,
                "cfg_scale": 3.0,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating speech (this may take 20-40s)...")

        messages, success = self.send_request_to_bridge(request, timeout=90)

        if not success or not self.require_no_error(messages):
            return False

        audio_message = self.require_message(messages, "audio.generated", request_id)
        if not audio_message or not self.require_completion(messages, request_id):
            return False

        path = audio_message.get("path")
        if not path:
            self.log("✗ FAILED: audio.generated did not include a path", "ERROR")
            return False

        self.generated_files.append(path)
        expected_sample_rate = audio_message.get("sample_rate")
        if not isinstance(expected_sample_rate, int):
            expected_sample_rate = None
        return self.validate_wav(path, expected_sample_rate=expected_sample_rate)

    def test_audio_missing_text_returns_error(self) -> bool:
        """Invalid speech request returns JSON error without loading a model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 7: Audio Missing Text Error")
        self.log("=" * 70)

        request_id = "integration-audio-missing-text"
        request = {
            "type": "audio.speech",
            "model": "kugelaudio/kugelaudio-0-open",
            "request_id": request_id,
            "messages": [{"role": "user", "content": ""}],
            "output_dir": str(GENERATED_SPEECH_DIR),
        }

        messages, _ = self.send_request_to_bridge(request, timeout=30)
        errors = [
            m
            for m in messages
            if m.get("type") == "error" and m.get("request_id") == request_id
        ]
        if not errors:
            self.log("✗ FAILED: Missing speech text did not return an error", "ERROR")
            return False

        self.log(f"✓ Error returned: {errors[0].get('message')}")
        return "No text provided" in errors[0].get("message", "")

    # ==========================================================================
    # TEST 6: Music Generation (ACE-Step)
    # ==========================================================================
    def test_music_generation(self) -> bool:
        """Test music generation with ACE-Step."""
        self.log("\n" + "=" * 70)
        self.log("TEST 8: Music Generation (ACE-Step)")
        self.log("=" * 70)

        request_id = "integration-music-generate"
        request = {
            "type": "music.generate",
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "request_id": request_id,
            "messages": [{"role": "user", "content": "upbeat electronic dance music"}],
            "output_dir": str(GENERATED_MUSIC_DIR),
            "parameters": {
                "caption": "upbeat electronic dance music",
                "lyrics": "[Instrumental]",
                "instrumental": True,
                "duration": 10,
                "inference_steps": 4,
                "seed": 42,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating music via main bridge music.generate route...")

        messages, success = self.send_request_to_bridge(request, timeout=180)

        if not success or not self.require_no_error(messages):
            return False

        audio_message = self.require_message(messages, "audio.generated", request_id)
        if not audio_message or not self.require_completion(messages, request_id):
            return False

        path = audio_message.get("path")
        if not path:
            self.log("✗ FAILED: audio.generated did not include a path", "ERROR")
            return False

        self.generated_files.append(path)
        expected_sample_rate = audio_message.get("sample_rate")
        if not isinstance(expected_sample_rate, int):
            expected_sample_rate = None
        return self.validate_wav(path, minimum_duration=1.0, expected_sample_rate=expected_sample_rate)

    def test_control_routes(self) -> bool:
        """Test lightweight bridge control routes."""
        self.log("\n" + "=" * 70)
        self.log("TEST 9: Bridge Control Routes")
        self.log("=" * 70)

        ping_id = "integration-ping"
        ping_messages, ping_success = self.send_request_to_bridge(
            {"type": "ping", "request_id": ping_id},
            timeout=30,
        )
        if not ping_success or not self.require_message(ping_messages, "pong", ping_id):
            return False

        unload_id = "integration-unload"
        unload_messages, unload_success = self.send_request_to_bridge(
            {"type": "unload", "request_id": unload_id},
            timeout=30,
        )
        if not unload_success or not self.require_message(
            unload_messages, "model.unloaded", unload_id
        ):
            return False

        unknown_id = "integration-unknown"
        unknown_messages, _ = self.send_request_to_bridge(
            {"type": "not.a.real.route", "request_id": unknown_id},
            timeout=30,
        )
        errors = [
            m
            for m in unknown_messages
            if m.get("type") == "error" and m.get("request_id") == unknown_id
        ]
        if not errors:
            self.log("✗ FAILED: Unknown route did not return an error", "ERROR")
            return False

        self.log("✓ Control routes validated")
        return True

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
            ("Image Missing Prompt Error", self.test_image_missing_prompt_returns_error, False),
            ("Audio/Speech (TTS)", self.test_audio_speech, True),
            ("Audio Missing Text Error", self.test_audio_missing_text_returns_error, False),
            ("Music Generation (ACE-Step)", self.test_music_generation, True),
            ("Bridge Control Routes", self.test_control_routes, False),
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
