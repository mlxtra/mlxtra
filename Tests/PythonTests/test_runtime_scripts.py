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
            set(manifest["supportedModels"]),
            set(bash_array("RUNTIME_SUPPORTED_MODELS")),
        )

    def test_runtime_supported_models_cover_bundled_catalog(self):
        catalog = json.loads(MODEL_CATALOG.read_text())
        catalog_model_ids = {
            model["modelId"]
            for model in catalog["models"]
            if model.get("runtime", {}).get("compatibilityApi") == 1
        }

        supported_models = set(bash_array("RUNTIME_SUPPORTED_MODELS"))

        self.assertFalse(
            catalog_model_ids - supported_models,
            "Runtime supported models must include every bundled catalog model id.",
        )

    def test_validate_runtime_bundle_writes_xcode_output_stamp(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            stamp_path = Path(temporary_directory) / "validation.stamp"
            env = os.environ.copy()
            env.update(
                {
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
