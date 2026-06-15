#!/usr/bin/env python3
"""
Integration test for ACE-Step music generation.
Tests the full end-to-end pipeline using subprocess (like the actual app).
"""

import json
import os
import subprocess
import sys
import threading
import time
import wave
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
VENV_PYTHON = MUSIC_RUNTIME / "acestep-venv/bin/python"
MAIN_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"
PYTHON_BRIDGE = RESOURCES / "python_bridge.py"
GENERATED_MUSIC_DIR = (
    APP_SUPPORT / "GeneratedMusic"
)
ACESTEP_CHECKPOINTS_DIR = APP_SUPPORT / "checkpoints"
REQUIRE_ALL_MODELS = (
    os.environ.get("MLXTRA_REQUIRE_ALL_MODELS") == "1"
    or "--strict" in sys.argv[1:]
)
ALLOW_MODEL_DOWNLOADS = (
    os.environ.get("MLXTRA_ALLOW_MODEL_DOWNLOADS") == "1"
    or "--allow-downloads" in sys.argv[1:]
)


def path_has_content(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
        return resolved.is_file() and resolved.stat().st_size > 0
    except OSError:
        return False


def ace_step_required_model_files() -> dict[str, Path]:
    return {
        "DiT model": ACESTEP_CHECKPOINTS_DIR
        / "acestep-v15-turbo"
        / "model.safetensors",
        "VAE": ACESTEP_CHECKPOINTS_DIR
        / "vae"
        / "diffusion_pytorch_model.safetensors",
        "Text encoder": ACESTEP_CHECKPOINTS_DIR
        / "Qwen3-Embedding-0.6B"
        / "model.safetensors",
        "LM": ACESTEP_CHECKPOINTS_DIR
        / "acestep-5Hz-lm-1.7B"
        / "model.safetensors",
    }


def ace_step_model_is_complete() -> bool:
    return all(path_has_content(path) for path in ace_step_required_model_files().values())


class MusicGenerationIntegrationTest:
    def __init__(self):
        self.results = []
        self.output_files = []
        self.skipped_tests = set()

    def log(self, message: str, level: str = "INFO"):
        """Log a message with timestamp."""
        timestamp = time.strftime("%H:%M:%S")
        print(f"[{timestamp}] [{level}] {message}")

    def missing_music_model_result(self, test_name: str) -> Optional[bool]:
        missing = [
            name
            for name, path in ace_step_required_model_files().items()
            if not path_has_content(path)
        ]
        message = "ACE-Step checkpoints are missing or incomplete: " + ", ".join(missing)

        if REQUIRE_ALL_MODELS:
            self.log(f"✗ FAILED: {message}", "ERROR")
            self.log(
                "   Strict model policy is enabled by MLXTRA_REQUIRE_ALL_MODELS=1.",
                "ERROR",
            )
            return False

        self.skipped_tests.add(test_name)
        self.log(f"↷ SKIPPED: {message}")
        self.log(
            "   Restore checkpoints locally, or run with MLXTRA_ALLOW_MODEL_DOWNLOADS=1 MLXTRA_REQUIRE_ALL_MODELS=1 to repair and gate."
        )
        return None

    def ensure_music_model_downloaded(self) -> bool:
        if ace_step_model_is_complete():
            return True

        if not ALLOW_MODEL_DOWNLOADS:
            return False

        helper = MUSIC_RUNTIME / "acestep_download_helper.py"
        if not helper.exists():
            self.log(f"ACE-Step download helper not found: {helper}", "ERROR")
            return False

        self.log("Downloading missing ACE-Step checkpoints because MLXTRA_ALLOW_MODEL_DOWNLOADS=1.")
        try:
            proc = subprocess.run(
                [
                    str(VENV_PYTHON),
                    "-u",
                    str(helper),
                    "ACE-Step/acestep-v15-turbo-continuous",
                    str(ACESTEP_CHECKPOINTS_DIR),
                ],
                capture_output=True,
                text=True,
                env=self.get_env(),
                timeout=1800,
            )
        except subprocess.TimeoutExpired:
            self.log("ACE-Step checkpoint download timed out.", "ERROR")
            return False

        for line in proc.stdout.splitlines()[-20:]:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            event_type = event.get("type")
            if event_type in {"download.progress", "download.complete", "download.error"}:
                self.log(f"  [download] {event.get('status') or event.get('message') or event_type}")

        if proc.returncode != 0:
            self.log(f"ACE-Step download helper exited with code {proc.returncode}", "ERROR")
            for line in proc.stderr.splitlines()[-20:]:
                self.log(f"  [download stderr] {line[:160]}", "ERROR")
            return False

        if not ace_step_model_is_complete():
            self.log("ACE-Step download completed but required checkpoint files are still incomplete.", "ERROR")
            return False

        self.log("ACE-Step checkpoints downloaded and verified.")
        return True

    def require_music_model(self, test_name: str) -> Optional[bool]:
        if self.ensure_music_model_downloaded():
            self.log("Local ACE-Step checkpoints verified.")
            return True

        if ace_step_model_is_complete():
            self.log("Local ACE-Step checkpoints verified.")
            return True
        return self.missing_music_model_result(test_name)

    def get_env(self) -> dict:
        """Get environment variables matching Swift's VLMExecutor.setupEnvironment()."""
        # Start with full system environment (like Swift does)
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
        env["ACESTEP_PYTHON"] = str(VENV_PYTHON)
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

        GENERATED_MUSIC_DIR.mkdir(parents=True, exist_ok=True)
        self.log(f"  ✓ Generated music directory: {GENERATED_MUSIC_DIR}")

        # Check model files without making default local development runs fail.
        self.log(f"\nCheckpoints directory: {ACESTEP_CHECKPOINTS_DIR}")

        all_present = True
        for name, path in ace_step_required_model_files().items():
            exists = path_has_content(path)
            status = "✓" if exists else "✗"
            self.log(f"  {status} {name}: {path.name}")
            if not exists:
                all_present = False

        if not all_present and ALLOW_MODEL_DOWNLOADS:
            return self.ensure_music_model_downloaded()

        return all_present or not REQUIRE_ALL_MODELS

    def test_model_normalization(self) -> bool:
        """Test 2: Verify model ID normalization logic."""
        self.log("\n" + "=" * 60)
        self.log("TEST 2: Model ID Normalization")
        self.log("=" * 60)

        if str(RESOURCES) not in sys.path:
            sys.path.insert(0, str(RESOURCES))
        from bridge_utils import normalize_music_model_id

        test_cases = [
            ("ACE-Step/acestep-v15-turbo-continuous", "acestep-v15-turbo"),
            ("ACE-Step/acestep-v15-turbo-shift3", "acestep-v15-turbo"),
            ("acestep-v15-turbo", "acestep-v15-turbo"),
            ("ACE-Step/acestep-v15-turbo-rl", "acestep-v15-turbo"),
        ]

        all_passed = True
        for input_id, expected in test_cases:
            result = normalize_music_model_id(input_id)
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

    def validate_wav(
        self,
        path: str,
        minimum_duration: float = 1.0,
        expected_sample_rate: Optional[int] = None,
    ) -> bool:
        """Validate generated audio is a readable WAV with plausible metadata."""
        audio_path = Path(path)
        if not audio_path.exists():
            self.log(f"\n✗ FAILED: Audio file not found at {audio_path}", "ERROR")
            return False

        if audio_path.stat().st_size <= 0:
            self.log(f"\n✗ FAILED: Audio file is empty at {audio_path}", "ERROR")
            return False

        try:
            with wave.open(str(audio_path), "rb") as wav_file:
                channels = wav_file.getnchannels()
                sample_rate = wav_file.getframerate()
                frames = wav_file.getnframes()
        except wave.Error as exc:
            self.log(f"\n✗ FAILED: Invalid WAV file: {exc}", "ERROR")
            return False

        if channels <= 0 or sample_rate <= 0 or frames <= 0:
            self.log(
                "✗ FAILED: Invalid WAV metadata "
                f"channels={channels}, sample_rate={sample_rate}, frames={frames}",
                "ERROR",
            )
            return False

        duration = frames / sample_rate
        if duration < minimum_duration:
            self.log(
                f"✗ FAILED: WAV duration {duration:.2f}s is shorter than "
                f"{minimum_duration:.2f}s",
                "ERROR",
            )
            return False

        if expected_sample_rate is not None and sample_rate != expected_sample_rate:
            self.log(
                f"✗ FAILED: WAV sample rate {sample_rate}, "
                f"expected {expected_sample_rate}",
                "ERROR",
            )
            return False

        file_size = audio_path.stat().st_size / 1024 / 1024
        self.log(
            f"  WAV metadata: {sample_rate} Hz, {channels} ch, "
            f"{duration:.2f}s, {file_size:.2f} MB"
        )
        return True

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

        expected_sample_rate = audio_generated[0].get("sample_rate")
        if not isinstance(expected_sample_rate, int):
            expected_sample_rate = None

        if not self.validate_wav(
            audio_path,
            minimum_duration=1.0,
            expected_sample_rate=expected_sample_rate,
        ):
            return False

        self.output_files.append(audio_path)
        self.log("\n✓ SUCCESS!")
        self.log(f"  Audio file: {audio_path}")
        self.log(f"  Generation time: {elapsed:.2f}s")

        return True

    def test_direct_instrumental_generation(self) -> bool:
        """Test 3: Generate the same instrumental payload the app button sends."""
        self.log("\n" + "=" * 60)
        self.log("TEST 3: Direct Instrumental Generation")
        self.log("=" * 60)

        test_name = "Direct Instrumental Generation"
        preflight = self.require_music_model(test_name)
        if preflight is not True:
            return preflight is None

        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "output_dir": str(GENERATED_MUSIC_DIR),
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

        test_name = "Direct Vocal Generation With Lyrics"
        preflight = self.require_music_model(test_name)
        if preflight is not True:
            return preflight is None

        lyrics = "[Verse]\nNeon streets are waking\n[Chorus]\nWe rise into the morning"
        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "output_dir": str(GENERATED_MUSIC_DIR),
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

        test_name = "Main Bridge Music Forwarding"
        preflight = self.require_music_model(test_name)
        if preflight is not True:
            return preflight is None

        request = {
            "type": "music.generate",
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "request_id": "music-integration-main-bridge",
            "output_dir": str(GENERATED_MUSIC_DIR),
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
            assert proc.stderr is not None
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.close()

            stdout_lines = []
            stderr_lines = []
            stdout_lock = threading.Lock()
            stderr_lock = threading.Lock()

            def drain_stdout():
                assert proc is not None and proc.stdout is not None
                for line in proc.stdout:
                    with stdout_lock:
                        stdout_lines.append(line)

            def drain_stderr():
                assert proc is not None and proc.stderr is not None
                for line in proc.stderr:
                    with stderr_lock:
                        stderr_lines.append(line)

            stdout_thread = threading.Thread(target=drain_stdout, daemon=True)
            stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
            stdout_thread.start()
            stderr_thread.start()

            deadline = time.time() + 300
            seen_stdout_lines = 0
            saw_terminal_message = False
            while time.time() < deadline:
                with stdout_lock:
                    new_lines = stdout_lines[seen_stdout_lines:]
                    seen_stdout_lines = len(stdout_lines)

                for line in new_lines:
                    try:
                        payload = json.loads(line)
                    except json.JSONDecodeError:
                        self.log(f"  [non-json stdout] {line.strip()[:150]}", "ERROR")
                        continue

                    msg_type = payload.get("type")
                    if msg_type in ("system.ready", "model.loading", "model.loaded", "audio.generated", "error"):
                        self.log(f"  [{msg_type}] {json.dumps(payload)[:100]}...")
                    if msg_type in ("chat.completion.complete", "error"):
                        saw_terminal_message = True
                        break

                if saw_terminal_message:
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.1)

            elapsed = time.time() - start_time
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)
            with stderr_lock:
                stderr = "".join(stderr_lines)

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
            "output_dir": str(GENERATED_MUSIC_DIR),
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
        if proc.returncode == 0:
            self.log("\n✗ FAILED: Missing prompt returned exit code 0", "ERROR")
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
        self.log(f"App bundle: {APP_BUNDLE}")
        self.log(
            f"ACESTEP_CHECKPOINTS_DIR: {self.get_env()['ACESTEP_CHECKPOINTS_DIR']}"
        )
        self.log(
            "Model policy: "
            + (
                "strict fail on missing models"
                if REQUIRE_ALL_MODELS
                else "skip missing models by default"
            )
        )
        if ALLOW_MODEL_DOWNLOADS:
            self.log("Model downloads: enabled for missing checkpoint repair")

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

        self.log("\n" + "=" * 60)
        self.log("TEST SUMMARY")
        self.log("=" * 60)

        for name, passed in results:
            if name in self.skipped_tests:
                status = "↷ SKIP"
            else:
                status = "✓ PASS" if passed else "✗ FAIL"
            self.log(f"  {status}: {name}")

        all_passed = all(passed for _, passed in results)
        if all_passed and self.skipped_tests:
            self.log(
                f"\n✓ All non-skipped tests passed; {len(self.skipped_tests)} model-backed test(s) were skipped."
            )
            self.log("   Use --strict or MLXTRA_REQUIRE_ALL_MODELS=1 for a release gate.")
        else:
            self.log(
                "\n" + ("✓ All tests passed!" if all_passed else "✗ Some tests failed!")
            )

        return all_passed


if __name__ == "__main__":
    with prepared_music_runtime(RUNTIME, MUSIC_RUNTIME):
        test = MusicGenerationIntegrationTest()
        success = test.run()
    sys.exit(0 if success else 1)
