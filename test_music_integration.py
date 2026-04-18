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
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"


class MusicGenerationIntegrationTest:
    def __init__(self):
        self.results = []
        self.output_file = None

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

        return env

    def test_setup(self) -> bool:
        """Test 1: Verify setup and files are present."""
        self.log("=" * 60)
        self.log("TEST 1: Setup Verification")
        self.log("=" * 60)

        checks = [
            ("App bundle", APP_BUNDLE, APP_BUNDLE.exists()),
            ("Python interpreter", VENV_PYTHON, VENV_PYTHON.exists()),
            ("ACE-Step bridge", ACESTEP_BRIDGE, ACESTEP_BRIDGE.exists()),
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
            self.log(f"  {status} '{input_id}' → '{result}' (expected: '{expected}')")
            if not passed:
                all_passed = False

        return all_passed

    def test_music_generation(self) -> bool:
        """Test 3: Generate music via subprocess."""
        self.log("\n" + "=" * 60)
        self.log("TEST 3: Music Generation (via subprocess)")
        self.log("=" * 60)

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
        self.log(f"Using Python: {VENV_PYTHON}")
        self.log(f"Using bridge: {ACESTEP_BRIDGE}")
        self.log("\nStarting generation...")

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

            self.log(
                f"Process completed in {elapsed:.2f}s (exit code: {proc.returncode})"
            )

            # Parse stdout
            output_messages = []
            for line in proc.stdout.splitlines():
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
                    pass

            # Check stderr for important info
            if proc.stderr:
                stderr_lines = proc.stderr.splitlines()
                # Show only relevant lines
                for line in stderr_lines[-20:]:  # Last 20 lines
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

            # Check results
            errors = [m for m in output_messages if m.get("type") == "error"]
            audio_generated = [
                m for m in output_messages if m.get("type") == "audio.generated"
            ]

            if errors:
                self.log(f"\n✗ FAILED: {errors[0].get('message')}", "ERROR")
                return False

            if not audio_generated:
                self.log("\n✗ FAILED: No audio.generated message received", "ERROR")
                return False

            audio_path = audio_generated[0].get("path")
            self.output_file = audio_path

            if not audio_path or not Path(audio_path).exists():
                self.log(f"\n✗ FAILED: Audio file not found at {audio_path}", "ERROR")
                return False

            file_size = Path(audio_path).stat().st_size
            self.log(f"\n✓ SUCCESS!")
            self.log(f"  Audio file: {audio_path}")
            self.log(f"  File size: {file_size / 1024 / 1024:.2f} MB")
            self.log(f"  Duration: {elapsed:.2f}s")

            return True

        except subprocess.TimeoutExpired:
            self.log("\n✗ FAILED: Timeout after 120s", "ERROR")
            return False
        except Exception as e:
            self.log(f"\n✗ EXCEPTION: {e}", "ERROR")
            import traceback

            traceback.print_exc()
            return False

    def cleanup(self):
        """Clean up or report generated files."""
        if self.output_file and Path(self.output_file).exists():
            self.log(f"\nGenerated audio preserved at: {self.output_file}")

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
            ("Music Generation", self.test_music_generation),
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
