#!/usr/bin/env python3
"""
Comprehensive integration tests for all MLXtra model types:
- Chat/VLM (Qwen3.5)
- Image (FLUX.2-klein)
- Audio/TTS (locally available catalog model)
- Music (ACE-Step)

Tests the full end-to-end pipeline using the Python bridge subprocess.
"""

import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path
from typing import Optional

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


ALLOW_MODEL_DOWNLOADS = (
    os.environ.get("MLXTRA_ALLOW_MODEL_DOWNLOADS") == "1"
    or "--allow-downloads" in sys.argv[1:]
)
REQUIRE_ALL_MODELS = (
    os.environ.get("MLXTRA_REQUIRE_ALL_MODELS") == "1"
    or "--strict" in sys.argv[1:]
)
HF_CACHE = Path.home() / ".cache/huggingface/hub"
ACESTEP_CHECKPOINTS_DIR = Path.home() / "Library/Application Support/MLXtra/checkpoints"


def path_has_content(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
        return resolved.is_file() and resolved.stat().st_size > 0
    except OSError:
        return False


def hf_snapshot_candidates(model_id: str) -> list[Path]:
    cache_name = f"models--{model_id.replace('/', '--')}"
    snapshots_dir = HF_CACHE / cache_name / "snapshots"
    if not snapshots_dir.exists():
        return []

    return [
        path
        for path in sorted(
            snapshots_dir.iterdir(), key=lambda item: item.stat().st_mtime, reverse=True
        )
        if path.is_dir()
    ]


def hf_snapshot_has_metadata(snapshot: Path) -> bool:
    metadata_names = {
        "config.json",
        "model_index.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "preprocessor_config.json",
        "scheduler_config.json",
    }
    for path in snapshot.rglob("*"):
        if path.name in metadata_names and path_has_content(path):
            return True
    return False


def is_hf_weight_index(path: Path) -> bool:
    return path.name.endswith(".index.json")


def is_hf_weight_artifact(path: Path) -> bool:
    name = path.name.lower()
    if is_hf_weight_index(path):
        return False
    return name.endswith((".safetensors", ".bin", ".gguf", ".ckpt", ".pt"))


def declared_weight_files_are_complete(index_path: Path, snapshot: Path) -> bool:
    try:
        payload = json.loads(index_path.read_text())
    except (OSError, json.JSONDecodeError):
        return False

    weight_map = payload.get("weight_map")
    if not isinstance(weight_map, dict):
        return False

    declared_files = {
        filename
        for filename in weight_map.values()
        if isinstance(filename, str) and filename
    }
    if not declared_files:
        return False

    for filename in declared_files:
        candidates = (index_path.parent / filename, snapshot / filename)
        if not any(path_has_content(candidate) for candidate in candidates):
            return False
    return True


def hf_snapshot_is_complete(model_id: str) -> bool:
    for snapshot in hf_snapshot_candidates(model_id):
        if not hf_snapshot_has_metadata(snapshot):
            continue

        indexes = [
            path
            for path in snapshot.rglob("*.index.json")
            if path_has_content(path)
        ]
        if indexes:
            if all(declared_weight_files_are_complete(path, snapshot) for path in indexes):
                return True
            continue

        if any(
            is_hf_weight_artifact(path) and path_has_content(path)
            for path in snapshot.rglob("*")
        ):
            return True

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


APP_BUNDLE = resolve_app_bundle()
RESOURCES = APP_BUNDLE / "Contents/Resources"
APP_SUPPORT = Path.home() / "Library/Application Support/MLXtra"


def runtime_is_valid(path: Path) -> bool:
    return all(
        (path / relative_path).exists()
        for relative_path in [
            "venv/bin/python",
            "acestep-venv/bin/python",
            "python/Frameworks/Versions/3.12",
            "acestep_download_helper.py",
            "runtime-manifest.json",
        ]
    )


def resolve_runtime_dir() -> Path:
    candidates = []
    override = os.environ.get("MLXTRA_RUNTIME_DIR")
    if override:
        candidates.append(Path(override))
    candidates.extend(
        [
            APP_SUPPORT / "runtimes/macos-arm64/current",
            RESOURCES / "runtime/macos-arm64",
        ]
    )

    for candidate in candidates:
        if runtime_is_valid(candidate):
            return candidate
    return candidates[-1]


RUNTIME = resolve_runtime_dir()
VENV_PYTHON = RUNTIME / "venv/bin/python"
ACESTEP_PYTHON = RUNTIME / "acestep-venv/bin/python"
BRIDGE_SCRIPT = RESOURCES / "python_bridge.py"
ACESTEP_BRIDGE = RESOURCES / "acestep_bridge.py"
GENERATED_IMAGES_DIR = APP_SUPPORT / "GeneratedImages"
GENERATED_SPEECH_DIR = APP_SUPPORT / "GeneratedSpeech"
GENERATED_MUSIC_DIR = APP_SUPPORT / "GeneratedMusic"
MODEL_CATALOG_PATH = RESOURCES / "model-catalog.json"


def bundled_catalog_models(modality: Optional[str] = None) -> list[dict]:
    try:
        with MODEL_CATALOG_PATH.open("r", encoding="utf-8") as handle:
            catalog = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []

    models = catalog.get("models", [])
    if not isinstance(models, list):
        return []

    result = []
    for model in models:
        if not isinstance(model, dict):
            continue
        if modality is not None and model.get("modality") != modality:
            continue
        result.append(model)
    return result


def bundled_catalog_model(model_id: str) -> Optional[dict]:
    for model in bundled_catalog_models():
        if model.get("modelId") == model_id:
            return model
    return None


def bundled_runtime_options(model_id: str) -> dict:
    model = bundled_catalog_model(model_id)
    if not isinstance(model, dict):
        return {}
    runtime_options = model.get("runtimeOptions")
    return runtime_options if isinstance(runtime_options, dict) else {}


class MLXtraIntegrationTest:
    """Integration tests for all MLXtra model types."""

    def __init__(self):
        self.results = []
        self.generated_files = []
        self.skipped_tests = set()
        self.last_bridge_timings = []

    def log(self, message: str, level: str = "INFO"):
        """Log a message with timestamp."""
        timestamp = time.strftime("%H:%M:%S")
        print(f"[{timestamp}] [{level}] {message}")

    def missing_model_result(self, test_name: str, message: str) -> Optional[bool]:
        """Return None for a policy skip, False for a strict failure."""
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
            "   Restore/download the model locally, or set MLXTRA_ALLOW_MODEL_DOWNLOADS=1 to allow an explicit repair/download run."
        )
        return None

    def require_hf_model(self, test_name: str, model_id: str) -> Optional[bool]:
        if ALLOW_MODEL_DOWNLOADS:
            self.log(
                f"Model preflight: downloads enabled; bridge may repair/download {model_id}."
            )
            return True

        if hf_snapshot_is_complete(model_id):
            self.log(f"Local Hugging Face snapshot verified: {model_id}")
            return True

        return self.missing_model_result(
            test_name,
            f"{model_id} is missing or incomplete in the local Hugging Face cache.",
        )

    def select_catalog_hf_model(
        self, test_name: str, modality: str
    ) -> tuple[Optional[str], Optional[bool]]:
        models = bundled_catalog_models(modality)
        model_ids = [
            model.get("modelId")
            for model in models
            if isinstance(model.get("modelId"), str)
        ]
        if not model_ids:
            self.log(f"✗ FAILED: No bundled catalog models for modality {modality}", "ERROR")
            return None, False

        if ALLOW_MODEL_DOWNLOADS:
            model_id = model_ids[0]
            self.log(
                f"Model preflight: downloads enabled; using preferred catalog model {model_id}."
            )
            return model_id, True

        for model_id in model_ids:
            if hf_snapshot_is_complete(model_id):
                self.log(f"Local Hugging Face snapshot verified: {model_id}")
                return model_id, True

        result = self.missing_model_result(
            test_name,
            f"No bundled {modality} catalog model is complete in the local Hugging Face cache.",
        )
        return None, result

    def ensure_music_model_downloaded(self) -> bool:
        if ace_step_model_is_complete():
            return True

        if not ALLOW_MODEL_DOWNLOADS:
            return False

        helper = RUNTIME / "acestep_download_helper.py"
        if not helper.exists():
            self.log(f"ACE-Step download helper not found: {helper}", "ERROR")
            return False

        self.log("Downloading missing ACE-Step checkpoints because MLXTRA_ALLOW_MODEL_DOWNLOADS=1.")
        try:
            proc = subprocess.run(
                [
                    str(ACESTEP_PYTHON),
                    "-u",
                    str(helper),
                    "ACE-Step/acestep-v15-turbo-continuous",
                    str(ACESTEP_CHECKPOINTS_DIR),
                ],
                capture_output=True,
                text=True,
                env=self.get_bridge_env(),
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

        missing = [
            name
            for name, path in ace_step_required_model_files().items()
            if not path_has_content(path)
        ]
        return self.missing_model_result(
            test_name,
            "ACE-Step checkpoints are missing or incomplete: " + ", ".join(missing),
        )

    def get_bridge_env(self) -> dict:
        """Get environment variables for the Python bridge."""
        env = dict(os.environ)

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
        env.setdefault("MLXTRA_BRIDGE_TIMING", "1")

        return env

    def record_timing(
        self,
        timings: list[dict],
        name: str,
        started_at: float,
        ended_at: Optional[float] = None,
        **extra,
    ) -> None:
        ended_at = ended_at if ended_at is not None else time.perf_counter()
        timing = {
            "type": "trace.timing",
            "name": name,
            "duration_ms": round((ended_at - started_at) * 1000, 3),
        }
        timing.update({key: value for key, value in extra.items() if value is not None})
        timings.append(timing)

    def log_timing_summary(self, messages: list[dict]) -> None:
        timings = [
            *self.last_bridge_timings,
            *(m for m in messages if m.get("type") == "trace.timing"),
        ]
        if not timings:
            self.log("No timing events captured.", "WARNING")
            return

        self.log("\nTiming breakdown:")
        for timing in timings:
            name = timing.get("name", "unknown")
            duration = timing.get("duration_ms")
            detail = timing.get("detail")
            if isinstance(duration, (int, float)):
                line = f"  {name}: {duration:.1f} ms"
            else:
                line = f"  {name}: {duration}"
            if detail:
                line += f" ({detail})"
            self.log(line)

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

        except subprocess.TimeoutExpired as e:
            self.log(f"Timeout after {timeout}s", "ERROR")
            stdout = e.stdout or ""
            stderr = e.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            for line in stdout.splitlines()[-10:]:
                self.log(f"  [stdout before timeout] {line[:150]}", "ERROR")
            for line in stderr.splitlines()[-20:]:
                self.log(f"  [stderr before timeout] {line[:150]}", "ERROR")
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
            stderr_lines = []
            stdout_lines = queue.Queue()
            start_time = time.time()
            process_started_at = time.perf_counter()
            session_timings = []
            self.last_bridge_timings = session_timings

            def drain_stdout():
                if proc.stdout is None:
                    return
                for line in proc.stdout:
                    line = line.strip()
                    if line:
                        stdout_lines.put(line)

            def drain_stderr():
                if proc.stderr is None:
                    return
                for line in proc.stderr:
                    line = line.strip()
                    if not line:
                        continue
                    stderr_lines.append(line)
                    del stderr_lines[:-50]

            stdout_thread = threading.Thread(target=drain_stdout, daemon=True)
            stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
            stdout_thread.start()
            stderr_thread.start()

            for request in requests:
                if time.time() - start_time > timeout:
                    self.log(f"Session timeout after {timeout}s", "ERROR")
                    for line in stderr_lines[-20:]:
                        self.log(f"  [stderr before timeout] {line[:150]}", "ERROR")
                    proc.terminate()
                    return all_messages, False

                proc.stdin.write(json.dumps(request) + "\n")
                proc.stdin.flush()

                # Read responses until we get the completion signal for this request.
                # The bridge keeps model lifecycle events request-id agnostic for
                # compatibility with older Swift callers, so only let model.loaded
                # complete init. A late model.loaded must not finish a queued chat
                # request before the assistant response arrives.
                request_start = time.time()
                request_started_at = time.perf_counter()
                request_type = request.get("type")
                if request_type == "init":
                    request_timeout = 420
                elif request_type == "chat.completions":
                    request_timeout = 300
                else:
                    request_timeout = 180
                request_completed = False
                saw_system_ready = False
                saw_first_chunk = False

                while time.time() - request_start < request_timeout:
                    try:
                        line = stdout_lines.get(timeout=0.1)
                    except queue.Empty:
                        line = None

                    if line:
                        try:
                            msg = json.loads(line)
                            all_messages.append(msg)

                            message_type = msg.get("type")
                            if message_type == "system.ready" and not saw_system_ready:
                                self.record_timing(
                                    session_timings,
                                    "e2e.process_to_system_ready",
                                    process_started_at,
                                )
                                saw_system_ready = True
                            if message_type == "error":
                                request_completed = True
                                break
                            if request_type == "init" and message_type == "model.loaded":
                                self.record_timing(
                                    session_timings,
                                    "e2e.init_request_to_model_loaded",
                                    request_started_at,
                                )
                                request_completed = True
                                break
                            if request_type == "chat.completions":
                                if (
                                    message_type == "chat.completion.chunk"
                                    and not saw_first_chunk
                                ):
                                    self.record_timing(
                                        session_timings,
                                        "e2e.chat_request_to_first_chunk",
                                        request_started_at,
                                    )
                                    saw_first_chunk = True
                                if message_type in (
                                    "assistant",
                                    "chat.completion.complete",
                                ):
                                    self.record_timing(
                                        session_timings,
                                        "e2e.chat_request_to_complete",
                                        request_started_at,
                                    )
                                    request_completed = True
                                    break
                            elif request_type in (
                                "audio.speech",
                                "image.generate",
                                "music.generate",
                            ) and message_type == "chat.completion.complete":
                                self.record_timing(
                                    session_timings,
                                    f"e2e.{request_type}_request_to_complete",
                                    request_started_at,
                                )
                                request_completed = True
                                break
                        except json.JSONDecodeError:
                            pass

                    return_code = proc.poll()
                    if return_code is not None:
                        self.log(
                            f"Bridge process exited during {request.get('type')} with code {return_code}",
                            "ERROR",
                        )
                        for line in stderr_lines[-20:]:
                            self.log(f"  [stderr] {line[:150]}", "ERROR")
                        break

                if not request_completed and proc.poll() is None:
                    self.log(
                        f"Request {request_type} timed out after {request_timeout}s",
                        "ERROR",
                    )
                    for line in stderr_lines[-20:]:
                        self.log(f"  [stderr before timeout] {line[:150]}", "ERROR")
                    proc.terminate()
                    self.last_bridge_timings = session_timings
                    return all_messages, False

            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            stdout_thread.join(timeout=1)
            stderr_thread.join(timeout=1)

            success = not any(m.get("type") == "error" for m in all_messages)
            self.last_bridge_timings = session_timings
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
        self,
        path: str,
        minimum_duration: float = 0.1,
        expected_sample_rate: Optional[int] = None,
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

        output_dirs = (
            GENERATED_IMAGES_DIR,
            GENERATED_SPEECH_DIR,
            GENERATED_MUSIC_DIR,
        )
        for output_dir in output_dirs:
            output_dir.mkdir(parents=True, exist_ok=True)
            self.log(f"  ✓ Output directory: {output_dir}")

        # ACE-Step checkpoints are optional unless strict model coverage is requested.
        checkpoints_dir = ACESTEP_CHECKPOINTS_DIR
        self.log(f"\n  Checkpoints directory: {checkpoints_dir}")

        if not checkpoints_dir.exists():
            message = (
                "ACE-Step checkpoints directory does not exist; music generation "
                "tests will be skipped unless MLXTRA_REQUIRE_ALL_MODELS=1."
            )
            if ALLOW_MODEL_DOWNLOADS:
                self.log(f"  ↻ {message} Attempting repair/download.")
                return self.ensure_music_model_downloaded()

            if REQUIRE_ALL_MODELS:
                self.log(f"  ✗ {message}", "ERROR")
                return False

            self.log(f"  ↷ {message}")
            return True

        try:
            for item in sorted(checkpoints_dir.iterdir()):
                if item.is_dir():
                    self.log(f"  ✓ {item.name}/")
        except Exception as e:
            self.log(f"  Warning: Could not list checkpoints: {e}", "WARNING")

        return True

    def test_model_normalization(self) -> bool:
        """Test that HuggingFace repo IDs are normalized to local names."""
        self.log("\n" + "=" * 70)
        self.log("TEST 2: Model ID Normalization")
        self.log("=" * 70)

        try:
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
                self.log(f"  {status} '{input_id}' → '{result}'")
                if not passed:
                    all_passed = False

            return all_passed

        except Exception as e:
            self.log(f"Error: {e}", "ERROR")
            return False

    def test_chat_completion(self) -> bool:
        """Test chat completion with a simple model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 3: Chat/Completion (VLM)")
        self.log("=" * 70)

        test_name = "Chat/Completion (VLM)"
        model_id, preflight = self.select_catalog_hf_model(test_name, "vision")
        if preflight is not True:
            return preflight is None
        if model_id is None:
            return False

        # Use persistent session for chat (init + chat in same process)
        requests = [
            {"type": "init", "model_id": model_id, "backend": "vlm"},
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
        self.log_timing_summary(messages)

        if not success:
            errors = [m for m in messages if m.get("type") == "error"]
            if errors:
                self.log(f"✗ FAILED: {errors[0].get('message')}", "ERROR")
            else:
                self.log("✗ FAILED: Session failed", "ERROR")
            return False

        completions = [
            m for m in messages if m.get("type") == "chat.completion.complete"
        ]
        if completions:
            choices = completions[0].get("choices", [])
            if choices and choices[0].get("message", {}).get("content"):
                content = choices[0]["message"]["content"]
                self.log(f"✓ SUCCESS: Got response: '{content[:50]}...'")
                return True

        chunks = [m for m in messages if m.get("type") == "chat.completion.chunk"]
        if chunks:
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

    def test_image_generation(self) -> bool:
        """Test image generation with FLUX."""
        self.log("\n" + "=" * 70)
        self.log("TEST 4: Image Generation (FLUX)")
        self.log("=" * 70)

        test_name = "Image Generation (FLUX)"
        model_id = "black-forest-labs/FLUX.2-klein-4B"
        preflight = self.require_hf_model(test_name, model_id)
        if preflight is not True:
            return preflight is None

        request_id = "integration-image-generate"
        runtime_options = bundled_runtime_options(model_id)
        if not runtime_options:
            self.log(f"✗ FAILED: {model_id} has no catalog runtimeOptions", "ERROR")
            return False

        request = {
            "type": "image.generate",
            "model": model_id,
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
                "runtimeOptions": runtime_options,
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

    def test_audio_speech(self) -> bool:
        """Test text-to-speech with a locally available catalog audio model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 6: Audio/Speech (TTS)")
        self.log("=" * 70)

        test_name = "Audio/Speech (TTS)"
        model_id, preflight = self.select_catalog_hf_model(test_name, "audio")
        if not model_id:
            return preflight is None
        if preflight is not True:
            return preflight is None

        request_id = "integration-audio-speech"
        runtime_options = bundled_runtime_options(model_id)
        if not runtime_options:
            self.log(f"✗ FAILED: {model_id} has no catalog runtimeOptions", "ERROR")
            return False
        audio_options = runtime_options.get("audio", {})
        if not isinstance(audio_options, dict):
            audio_options = {}
        voice = str(audio_options.get("defaultVoice") or "default")

        request = {
            "type": "audio.speech",
            "model": model_id,
            "request_id": request_id,
            "messages": [{"role": "user", "content": "Hello world. This is a test."}],
            "output_dir": str(GENERATED_SPEECH_DIR),
            "parameters": {
                "voice": voice,
                "ddpm_steps": 4,
                "cfg_scale": 3.0,
                "runtimeOptions": runtime_options,
            },
        }

        self.log(f"Request: {json.dumps(request, indent=2)}")
        self.log("Generating speech (this may take a few minutes)...")

        messages, success = self.send_request_to_bridge(request, timeout=300)

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

    def test_audio_persistent_session(self) -> bool:
        """Test two speech turns in one bridge process."""
        self.log("\n" + "=" * 70)
        self.log("TEST 7: Audio Persistent Session")
        self.log("=" * 70)

        test_name = "Audio Persistent Session"
        model_id, preflight = self.select_catalog_hf_model(test_name, "audio")
        if not model_id:
            return preflight is None
        if preflight is not True:
            return preflight is None

        runtime_options = bundled_runtime_options(model_id)
        if not runtime_options:
            self.log(f"✗ FAILED: {model_id} has no catalog runtimeOptions", "ERROR")
            return False
        audio_options = runtime_options.get("audio", {})
        if not isinstance(audio_options, dict):
            audio_options = {}
        voice = str(audio_options.get("defaultVoice") or "default")

        requests = []
        for index, text in enumerate(("First short speech turn.", "Second short speech turn."), start=1):
            requests.append(
                {
                    "type": "audio.speech",
                    "model": model_id,
                    "request_id": f"integration-audio-persistent-{index}",
                    "messages": [{"role": "user", "content": text}],
                    "output_dir": str(GENERATED_SPEECH_DIR),
                    "parameters": {
                        "voice": voice,
                        "ddpm_steps": 4,
                        "cfg_scale": 3.0,
                        "runtimeOptions": runtime_options,
                    },
                }
            )

        messages, success = self.run_bridge_session(requests, timeout=420)
        if not success or not self.require_no_error(messages):
            return False

        for request in requests:
            request_id = request["request_id"]
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
            if not self.validate_wav(path, expected_sample_rate=expected_sample_rate):
                return False

        return True

    def test_audio_missing_text_returns_error(self) -> bool:
        """Invalid speech request returns JSON error without loading a model."""
        self.log("\n" + "=" * 70)
        self.log("TEST 8: Audio Missing Text Error")
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

    def test_music_generation(self) -> bool:
        """Test music generation with ACE-Step."""
        self.log("\n" + "=" * 70)
        self.log("TEST 8: Music Generation (ACE-Step)")
        self.log("=" * 70)

        test_name = "Music Generation (ACE-Step)"
        preflight = self.require_music_model(test_name)
        if preflight is not True:
            return preflight is None

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
        return self.validate_wav(
            path,
            minimum_duration=1.0,
            expected_sample_rate=expected_sample_rate,
        )

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

    def run(self) -> bool:
        """Run all integration tests."""
        self.log("\n" + "=" * 70)
        self.log("MLXtra Integration Test Suite")
        self.log("=" * 70)
        self.log(f"Python: {sys.version.split()[0]}")
        self.log(
            f"ACESTEP_CHECKPOINTS_DIR: {self.get_bridge_env()['ACESTEP_CHECKPOINTS_DIR']}"
        )
        self.log(
            "Model policy: "
            + (
                "strict fail on missing models"
                if REQUIRE_ALL_MODELS
                else "skip missing models by default"
            )
            + (
                "; explicit downloads/repair enabled"
                if ALLOW_MODEL_DOWNLOADS
                else "; downloads disabled"
            )
        )

        tests = [
            ("Setup Verification", self.test_setup, False),
            ("Model Normalization", self.test_model_normalization, False),
            ("Chat/Completion (VLM)", self.test_chat_completion, True),
            ("Image Generation (FLUX)", self.test_image_generation, True),
            (
                "Image Missing Prompt Error",
                self.test_image_missing_prompt_returns_error,
                False,
            ),
            ("Audio/Speech (TTS)", self.test_audio_speech, True),
            ("Audio Persistent Session", self.test_audio_persistent_session, True),
            (
                "Audio Missing Text Error",
                self.test_audio_missing_text_returns_error,
                False,
            ),
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

        self.log("\n" + "=" * 70)
        self.log("TEST SUMMARY")
        self.log("=" * 70)

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

        if self.generated_files:
            self.log("\nGenerated files:")
            for f in self.generated_files:
                self.log(f"  - {f}")

        return all_passed


if __name__ == "__main__":
    test = MLXtraIntegrationTest()
    success = test.run()
    sys.exit(0 if success else 1)
