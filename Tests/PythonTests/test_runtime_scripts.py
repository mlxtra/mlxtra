#!/usr/bin/env python3
"""Checks for runtime build/validation script drift."""

import json
import hashlib
import importlib.util
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "Scripts"
RUNTIME_MANIFEST = REPO_ROOT / "MLXtra/Resources/runtime/macos-arm64/runtime-manifest.json"
MODEL_CATALOG = REPO_ROOT / "MLXtra/Resources/model-catalog.json"
STABLE_CHANNEL = REPO_ROOT / "MLXtra/Resources/stable-channel.json"
HF_DOWNLOAD_HELPER = REPO_ROOT / "MLXtra/Resources/runtime/macos-arm64/hf_download_helper.py"
RUNTIME_LOCK_VALIDATOR = SCRIPTS_DIR / "runtime-locks/validate-runtime-lock.py"
RUNTIME_LOCK = SCRIPTS_DIR / "runtime-locks/macos-arm64.lock.json"


def bash_array(name: str) -> list[str]:
    command = f"source {SCRIPTS_DIR / 'runtime-dependencies.sh'}; printf '%s\\n' \"${{{name}[@]}}\""
    result = subprocess.run(
        ["bash", "-lc", command],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


class RuntimeScriptTests(unittest.TestCase):
    def test_hf_download_helper_hashes_large_files_by_default(self):
        spec = importlib.util.spec_from_file_location("hf_download_helper", HF_DOWNLOAD_HELPER)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        fake_huggingface_hub = types.ModuleType("huggingface_hub")
        fake_huggingface_hub.HfApi = object
        fake_huggingface_hub.snapshot_download = lambda *args, **kwargs: None
        fake_tqdm = types.ModuleType("tqdm")
        fake_tqdm_auto = types.ModuleType("tqdm.auto")

        class FakeTqdm:
            def __init__(self, *args, **kwargs):
                pass

        fake_tqdm_auto.tqdm = FakeTqdm
        with mock.patch.dict(
            "sys.modules",
            {
                "huggingface_hub": fake_huggingface_hub,
                "tqdm": fake_tqdm,
                "tqdm.auto": fake_tqdm_auto,
            },
        ):
            spec.loader.exec_module(module)

        with mock.patch.dict(
            os.environ,
            {"MLXTRA_HASH_VERIFY_MAX_BYTES": "1"},
            clear=True,
        ):
            self.assertTrue(module.should_hash_file(1024))

        with mock.patch.dict(
            os.environ,
            {
                "MLXTRA_HASH_VERIFY_MAX_BYTES": "1",
                "MLXTRA_SKIP_LARGE_FILE_HASHES": "1",
            },
            clear=True,
        ):
            self.assertFalse(module.should_hash_file(1024))

    def test_runtime_scripts_are_valid_bash(self):
        for script_name in (
            "runtime-dependencies.sh",
            "generate-runtime-lockfiles.sh",
            "build-runtime-bundle.sh",
            "validate-runtime-bundle.sh",
        ):
            with self.subTest(script=script_name):
                subprocess.run(
                    ["bash", "-n", str(SCRIPTS_DIR / script_name)],
                    cwd=REPO_ROOT,
                    check=True,
                )

    def test_runtime_lock_validator_is_valid_python(self):
        subprocess.run(
            ["python3", "-m", "py_compile", str(RUNTIME_LOCK_VALIDATOR)],
            cwd=REPO_ROOT,
            check=True,
        )

    def test_runtime_dependency_lock_matches_generated_content(self):
        result = subprocess.run(
            ["python3", str(RUNTIME_LOCK_VALIDATOR)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_dependency_lock_detects_drift(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            lock_path = Path(temporary_directory) / "macos-arm64.lock.json"
            lock = json.loads(RUNTIME_LOCK.read_text())
            lock["pythonPackage"]["sha256"] = "0" * 64
            lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")

            result = subprocess.run(
                [
                    "python3",
                    str(RUNTIME_LOCK_VALIDATOR),
                    "--lock-file",
                    str(lock_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime dependency lock is out of date", result.stderr)
            self.assertIn("sha256", result.stderr)

    def test_runtime_manifest_uses_shared_dependency_pins(self):
        manifest = json.loads(RUNTIME_MANIFEST.read_text())

        self.assertEqual(set(manifest["packages"]), set(bash_array("RUNTIME_MAIN_PACKAGES")))
        self.assertTrue(
            any(
                package.startswith("git+https://github.com/omercelik/mflux.git@")
                for package in bash_array("RUNTIME_MAIN_INSTALL_PACKAGES")
            )
        )
        self.assertEqual(
            set(manifest["supportedBackends"]),
            set(bash_array("RUNTIME_SUPPORTED_BACKENDS")),
        )
        self.assertEqual(
            set(manifest["capabilities"]),
            set(bash_array("RUNTIME_CAPABILITIES")),
        )
        self.assertEqual(
            set(manifest["imageRuntimes"]["mflux"]["configs"]),
            set(bash_array("RUNTIME_MFLUX_CONFIGS")),
        )
        self.assertEqual(
            set(manifest["imageRuntimes"]["mflux"]["classes"]),
            set(bash_array("RUNTIME_MFLUX_CLASSES")),
        )
        self.assertEqual(
            set(map(str, manifest["imageRuntimes"]["mflux"]["quantizeBits"])),
            set(bash_array("RUNTIME_MFLUX_QUANTIZE_BITS")),
        )
        self.assertEqual(
            set(manifest["audioRuntimes"]["adapters"]),
            set(bash_array("RUNTIME_AUDIO_ADAPTERS")),
        )

    def test_runtime_mflux_capabilities_cover_bundled_image_catalog(self):
        catalog = json.loads(MODEL_CATALOG.read_text())
        runtime_manifest = json.loads(RUNTIME_MANIFEST.read_text())
        supported_mflux_configs = set(runtime_manifest["imageRuntimes"]["mflux"]["configs"])

        catalog_mflux_configs = {
            model["runtimeOptions"]["mflux"]["config"]
            for model in catalog["models"]
            if model.get("runtime", {}).get("compatibilityApi") == 1
            and model.get("backend") == "image"
            and "mflux" in model.get("runtimeOptions", {})
        }

        self.assertFalse(
            catalog_mflux_configs - supported_mflux_configs,
            "Runtime mflux configs must include every bundled image catalog config.",
        )

    def test_runtime_audio_adapters_cover_bundled_audio_catalog(self):
        catalog = json.loads(MODEL_CATALOG.read_text())
        runtime_manifest = json.loads(RUNTIME_MANIFEST.read_text())
        supported_adapters = set(runtime_manifest["audioRuntimes"]["adapters"])

        catalog_adapters = {
            model["runtimeOptions"]["audio"]["adapter"]
            for model in catalog["models"]
            if model.get("runtime", {}).get("compatibilityApi") == 1
            and model.get("backend") == "audio"
            and "audio" in model.get("runtimeOptions", {})
        }

        self.assertFalse(
            catalog_adapters - supported_adapters,
            "Runtime audio adapters must include every bundled audio catalog adapter.",
        )

    def test_validate_runtime_bundle_writes_xcode_output_stamp(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            stamp_path = Path(temporary_directory) / "validation.stamp"
            env = os.environ.copy()
            env.update(
                {
                    "MLXTRA_SKIP_RUNTIME_VALIDATION": "1",
                    "SCRIPT_INPUT_FILE_COUNT": "1",
                    "SCRIPT_OUTPUT_FILE_COUNT": "1",
                    "SCRIPT_OUTPUT_FILE_0": str(stamp_path),
                }
            )

            subprocess.run(
                ["bash", str(SCRIPTS_DIR / "validate-runtime-bundle.sh")],
                cwd=REPO_ROOT,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(stamp_path.read_text(), "validated\n")

    def test_release_metadata_validator_detects_runtime_channel_drift(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            channel_path = Path(temporary_directory) / "stable-channel.json"
            channel = json.loads(STABLE_CHANNEL.read_text())
            channel["catalog"]["sha256"] = hashlib.sha256(MODEL_CATALOG.read_bytes()).hexdigest()
            channel["catalog"]["sizeBytes"] = MODEL_CATALOG.stat().st_size
            channel["runtimes"][0]["version"] = "9.9.9"
            channel_path.write_text(json.dumps(channel), encoding="utf-8")

            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPTS_DIR / "validate-release-metadata.py"),
                    "--catalog",
                    str(MODEL_CATALOG),
                    "--channel",
                    str(channel_path),
                    "--runtime-manifest",
                    str(RUNTIME_MANIFEST),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match bundled runtime manifest", result.stderr)

            allowed_result = subprocess.run(
                [
                    "python3",
                    str(SCRIPTS_DIR / "validate-release-metadata.py"),
                    "--catalog",
                    str(MODEL_CATALOG),
                    "--channel",
                    str(channel_path),
                    "--runtime-manifest",
                    str(RUNTIME_MANIFEST),
                    "--allow-runtime-version-drift",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(allowed_result.returncode, 0, allowed_result.stderr)
            self.assertIn("does not match bundled runtime manifest", allowed_result.stderr)


if __name__ == "__main__":
    unittest.main()
