#!/usr/bin/env python3
"""
Integration test for ACE-Step music generation.
Tests the full end-to-end pipeline using subprocess (like the actual app).
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Setup paths
APP_BUNDLE = Path(
    "/Users/omercelik/Library/Developer/Xcode/DerivedData/MLXHub-ayxjdxuxnnlpflbgqijatrzqclph/Build/Products/Debug/MLXHub.app"
)
RESOURCES = APP_BUNDLE / "Contents/Resources"
RUNTIME = RESOURCES / "runtime/macos-arm64"
VENV_PYTHON = RUNTIME / "acestep-venv/bin/python"
MAIN_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"
PYTHON_BRIDGE = RESOURCES / "python_bridge.py"


class MusicGenerationIntegrationTest:
    def __init__(self):
        self.results = []
        self.output_files = []

    def log(self, message: str, level: str = "INFO"):
        """Log a message with timestamp."""
        timestamp = time.strftime("%H:%M:%S")
        print(f"[{timestamp}] [{level}] {message}")

    def get_env(self) -> dict:
        """Get environment variables matching Swift's VLMExecutor.setupEnvironment()."""
        # Start with full system environment (like Swift does)
        env = dict(os.environ)

        # Remove Python-related env vars that could cause conflicts (matching Swift)
        env.pop("PYTHONPATH", None)
        env.pop("PYTHONHOME", None)
        env.pop("VIRTUAL_ENV", None)
        env.pop("CONDA_PREFIX", None)
        env.pop("CONDA_DEFAULT_ENV", None)
        env.pop("PYENV_ROOT", None)
        env.pop("PYENV_VERSION", None)

        # Set critical env vars for the bundled Python (matching Swift)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONHOME"] = str(APP_BUNDLE / "Contents/Resources/runtime/macos-arm64/python/Frameworks/Versions/3.12")
        env["HF_HOME"] = str(Path.home() / ".cache/huggingface")
        env["HF_HUB_CACHE"] = str(Path.home() / ".cache/huggingface/hub")
        env["ACESTEP_CHECKPOINTS_DIR"] = str(
            Path.home() / "Library/Application Support/MLXHub/checkpoints"
        )
        env["MTL_DEBUG_LAYER"] = "0"
        env["MTL_SHADER_VALIDATION"] = "0"

        return env

    def test_setup(self) -> bool:
        """Test 1: Verify setup and files are present."""
        self.log("=" * 60)
        self.log("TEST 1: Setup Verification")
        self.log("=" * 60)

        checks = [
            ("App bundle", APP_BUNDLE, APP_BUNDLE.exists()),
            ("Python interpreter", VENV_PYTHON, VENV_PYTHON.exists()),
            ("Main Python interpreter", MAIN_PYTHON, MAIN_PYTHON.exists()),
            ("ACE-Step bridge", ACESTEP_BRIDGE, ACESTEP_BRIDGE.exists()),
            ("Python bridge", PYTHON_BRIDGE, PYTHON_BRIDGE.exists()),
        ]

        all_good = True
        for name, path, exists in checks:
            status = "✓" if exists else "✗"
            self.log(f"  {status} {name}: {path}")
            if not exists:
                all_good = False

        if not all_good:
            return False

        # Check model files
        checkpoints_dir = Path.home() / "Library/Application Support/MLXHub/checkpoints"
        self.log(f"\nCheckpoints directory: {checkpoints_dir}")

        required = {
            "DiT model": checkpoints_dir / "acestep-v15-turbo" / "model.safetensors",
            "VAE": checkpoints_dir / "vae" / "diffusion_pytorch_model.safetensors",
            "Text encoder": checkpoints_dir
            / "Qwen3-Embedding-0.6B"
            / "model.safetensors",
            "LM": checkpoints_dir / "acestep-5Hz-lm-1.7B" / "model.safetensors",
        }

        all_present = True
        for name, path in required.items():
            exists = path.exists()
            status = "✓" if exists else "✗"
            self.log(f"  {status} {name}: {path.name}")
            if not exists:
                all_present = False

        return all_present

    def test_model_normalization(self) -> bool:
        """Test 2: Verify model ID normalization logic."""
        self.log("\n" + "=" * 60)
        self.log("TEST 2: Model ID Normalization")
        self.log("=" * 60)

        # Read normalization function from acestep_bridge.py
        bridge_code = ACESTEP_BRIDGE.read_text()

        # Extract and exec the normalization function
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
            self.log(f"  {status} '{input_id}' → '{result}' (expected: '{expected}')")
            if not passed:
                all_passed = False

        return all_passed

    def run_acestep_generation(self, request: dict, label: str) -> bool:
        """Generate music by invoking the ACE-Step helper directly."""
        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log(f"Using Python: {VENV_PYTHON}")
        self.log(f"Using bridge: {ACESTEP_BRIDGE}")
        self.log(f"\nStarting {label}...")

        try:
            start_time = time.time()
            proc = subprocess.run(
                [str(VENV_PYTHON), "-u", str(ACESTEP_BRIDGE)],
                input=json.dumps(request) + "\n",
                capture_output=True,
                text=True,
                env=self.get_env(),
                timeout=300,
            )
            elapsed = time.time() - start_time
            self.log(f"Process completed in {elapsed:.2f}s (exit code: {proc.returncode})")
            return self.validate_generation_output(proc.stdout, proc.stderr, elapsed)
        except subprocess.TimeoutExpired:
            self.log("\n✗ FAILED: Timeout after 300s", "ERROR")
            return False
        except Exception as e:
            self.log(f"\n✗ EXCEPTION: {e}", "ERROR")
            import traceback

            traceback.print_exc()
            return False

    def validate_generation_output(self, stdout: str, stderr: str, elapsed: float) -> bool:
        """Validate bridge stdout contains JSON events for a generated audio file."""
        output_messages = []
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                output_messages.append(msg)
                msg_type = msg.get("type")
                if msg_type in (
                    "model.loading",
                    "model.loaded",
                    "error",
                    "audio.generated",
                ):
                    self.log(f"  [{msg_type}] {json.dumps(msg)[:100]}...")
            except json.JSONDecodeError:
                self.log(f"  [non-json stdout] {line[:150]}", "ERROR")
                return False

        if stderr:
            stderr_lines = stderr.splitlines()
            for line in stderr_lines[-20:]:
                if any(
                    x in line.lower()
                    for x in [
                        "error",
                        "exception",
                        "failed",
                        "complete",
                        "saved",
                        "generation",
                    ]
                ):
                    self.log(f"  [stderr] {line[:150]}")

        errors = [m for m in output_messages if m.get("type") == "error"]
        audio_generated = [
            m for m in output_messages if m.get("type") == "audio.generated"
        ]
        completions = [
            m for m in output_messages if m.get("type") == "chat.completion.complete"
        ]

        if errors:
            self.log(f"\n✗ FAILED: {errors[0].get('message')}", "ERROR")
            return False

        if not audio_generated:
            self.log("\n✗ FAILED: No audio.generated message received", "ERROR")
            return False

        if not completions:
            self.log("\n✗ FAILED: No chat.completion.complete message received", "ERROR")
            return False

        audio_path = audio_generated[0].get("path")
        if not audio_path or not Path(audio_path).exists():
            self.log(f"\n✗ FAILED: Audio file not found at {audio_path}", "ERROR")
            return False

        file_size = Path(audio_path).stat().st_size
        if file_size <= 0:
            self.log(f"\n✗ FAILED: Audio file is empty at {audio_path}", "ERROR")
            return False

        self.output_files.append(audio_path)
        self.log("\n✓ SUCCESS!")
        self.log(f"  Audio file: {audio_path}")
        self.log(f"  File size: {file_size / 1024 / 1024:.2f} MB")
        self.log(f"  Duration: {elapsed:.2f}s")

        return True

    def test_direct_instrumental_generation(self) -> bool:
        """Test 3: Generate the same instrumental payload the app button sends."""
        self.log("\n" + "=" * 60)
        self.log("TEST 3: Direct Instrumental Generation")
        self.log("=" * 60)

        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "messages": [{"role": "user", "content": "moody cyberpunk instrumental"}],
            "parameters": {
                "caption": "moody cyberpunk instrumental",
                "lyrics": "[Instrumental]",
                "instrumental": True,
                "duration": 10,
                "inference_steps": 4,
                "seed": 42,
            },
        }

        return self.run_acestep_generation(request, "direct instrumental generation")

    def test_direct_vocal_generation_with_lyrics(self) -> bool:
        """Test 4: Generate with the vocals + lyrics payload the app button sends."""
        self.log("\n" + "=" * 60)
        self.log("TEST 4: Direct Vocal Generation With Lyrics")
        self.log("=" * 60)

        lyrics = "[Verse]\nNeon streets are waking\n[Chorus]\nWe rise into the morning"
        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "messages": [{"role": "user", "content": "warm pop song with vocals"}],
            "parameters": {
                "caption": "warm pop song with vocals",
                "lyrics": lyrics,
                "instrumental": False,
                "duration": 10,
                "inference_steps": 4,
                "seed": 43,
            },
        }

        return self.run_acestep_generation(request, "direct vocal generation")

    def test_main_bridge_music_forwarding(self) -> bool:
        """Test 5: Generate through python_bridge.py, matching the app runtime path."""
        self.log("\n" + "=" * 60)
        self.log("TEST 5: Main Bridge Music Forwarding")
        self.log("=" * 60)

        request = {
            "type": "music.generate",
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "request_id": "music-integration-main-bridge",
            "messages": [{"role": "user", "content": "short upbeat synth theme"}],
            "parameters": {
                "caption": "short upbeat synth theme",
                "lyrics": "[Instrumental]",
                "instrumental": True,
                "duration": 10,
                "inference_steps": 4,
                "seed": 44,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log(f"Using Python: {MAIN_PYTHON}")
        self.log(f"Using bridge: {PYTHON_BRIDGE}")
        self.log("\nStarting main bridge forwarding...")

        proc = None
        try:
            start_time = time.time()
            proc = subprocess.Popen(
                [str(MAIN_PYTHON), "-u", str(PYTHON_BRIDGE)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.get_env(),
            )

            assert proc.stdin is not None
            assert proc.stdout is not None
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.close()

            stdout_lines = []
            deadline = time.time() + 300
            while time.time() < deadline:
                line = proc.stdout.readline()
                if not line:
                    if proc.poll() is not None:
                        break
                    time.sleep(0.1)
                    continue

                stdout_lines.append(line)
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    self.log(f"  [non-json stdout] {line.strip()[:150]}", "ERROR")
                    continue

                msg_type = payload.get("type")
                if msg_type in ("system.ready", "model.loading", "model.loaded", "audio.generated", "error"):
                    self.log(f"  [{msg_type}] {json.dumps(payload)[:100]}...")
                if msg_type in ("chat.completion.complete", "error"):
                    break

            elapsed = time.time() - start_time
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            stderr = proc.stderr.read() if proc.stderr else ""

            return self.validate_generation_output("".join(stdout_lines), stderr, elapsed)
        except Exception as e:
            self.log(f"\n✗ EXCEPTION: {e}", "ERROR")
            if proc and proc.poll() is None:
                proc.kill()
            return False

    def test_missing_prompt_returns_error(self) -> bool:
        """Test 6: Invalid Generate request returns JSON error instead of hanging."""
        self.log("\n" + "=" * 60)
        self.log("TEST 6: Missing Prompt Error")
        self.log("=" * 60)

        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "messages": [{"role": "user", "content": ""}],
            "parameters": {},
        }

        proc = subprocess.run(
            [str(VENV_PYTHON), "-u", str(ACESTEP_BRIDGE)],
            input=json.dumps(request) + "\n",
            capture_output=True,
            text=True,
            env=self.get_env(),
            timeout=30,
        )
        messages = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        errors = [m for m in messages if m.get("type") == "error"]
        if not errors:
            self.log("\n✗ FAILED: Missing prompt did not return an error", "ERROR")
            return False

        self.log(f"  [error] {errors[0].get('message')}")
        return "No prompt provided" in errors[0].get("message", "")

    def cleanup(self):
        """Clean up or report generated files."""
        for output_file in self.output_files:
            if output_file and Path(output_file).exists():
                self.log(f"\nGenerated audio preserved at: {output_file}")

    def run(self) -> bool:
        """Run all tests."""
        self.log("\n" + "=" * 60)
        self.log("ACE-Step Music Generation Integration Test")
        self.log("=" * 60)
        self.log(f"Python: {sys.version.split()[0]}")
        self.log(
            f"ACESTEP_CHECKPOINTS_DIR: {self.get_env()['ACESTEP_CHECKPOINTS_DIR']}"
        )

        tests = [
            ("Setup Verification", self.test_setup),
            ("Model Normalization", self.test_model_normalization),
            ("Direct Instrumental Generation", self.test_direct_instrumental_generation),
            ("Direct Vocal Generation With Lyrics", self.test_direct_vocal_generation_with_lyrics),
            ("Main Bridge Music Forwarding", self.test_main_bridge_music_forwarding),
            ("Missing Prompt Error", self.test_missing_prompt_returns_error),
        ]

        results = []
        for name, test_func in tests:
            try:
                passed = test_func()
                results.append((name, passed))
            except Exception as e:
                self.log(f"EXCEPTION in {name}: {e}", "ERROR")
                results.append((name, False))

        self.cleanup()

        # Summary
        self.log("\n" + "=" * 60)
        self.log("TEST SUMMARY")
        self.log("=" * 60)

        for name, passed in results:
            status = "✓ PASS" if passed else "✗ FAIL"
            self.log(f"  {status}: {name}")

        all_passed = all(passed for _, passed in results)
        self.log(
            "\n" + ("✓ All tests passed!" if all_passed else "✗ Some tests failed!")
        )

        return all_passed


if __name__ == "__main__":
    test = MusicGenerationIntegrationTest()
    success = test.run()
    sys.exit(0 if success else 1)
