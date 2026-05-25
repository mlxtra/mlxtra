#!/usr/bin/env python3
"""Checks for runtime build/validation script drift."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "Scripts"
RUNTIME_MANIFEST = REPO_ROOT / "MLXtra/Resources/runtime/macos-arm64/runtime-manifest.json"
MODEL_CATALOG = REPO_ROOT / "MLXtra/Resources/model-catalog.json"


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
    def test_runtime_scripts_are_valid_bash(self):
        for script_name in (
            "runtime-dependencies.sh",
            "build-runtime-bundle.sh",
            "validate-runtime-bundle.sh",
        ):
            with self.subTest(script=script_name):
                subprocess.run(
                    ["bash", "-n", str(SCRIPTS_DIR / script_name)],
                    cwd=REPO_ROOT,
                    check=True,
                )

    def test_runtime_manifest_uses_shared_dependency_pins(self):
        manifest = json.loads(RUNTIME_MANIFEST.read_text())

        self.assertEqual(set(manifest["packages"]), set(bash_array("RUNTIME_MAIN_PACKAGES")))
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


if __name__ == "__main__":
    unittest.main()
