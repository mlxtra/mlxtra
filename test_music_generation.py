#!/usr/bin/env python3
"""Test script for ACE-Step music generation."""

import json
import os
import sys
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parent
RESOURCES_DIR = REPO_ROOT / "MLXtra/Resources"

if str(RESOURCES_DIR) not in sys.path:
    sys.path.insert(0, str(RESOURCES_DIR))

from bridge_utils import normalize_music_model_id


def _derived_data_runtime_candidates() -> list[Path]:
    derived_data = Path.home() / "Library/Developer/Xcode/DerivedData"
    return list(
        derived_data.glob(
            "MLXtra-*/Build/Products/Debug/MLXtra.app/Contents/Resources/runtime/macos-arm64"
        )
    )


def _newest_existing_runtime() -> Optional[Path]:
    candidates = [path for path in _derived_data_runtime_candidates() if path.exists()]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def resolve_runtime_dir() -> Path:
    override = os.environ.get("MLXTRA_RUNTIME_DIR")
    if override:
        return Path(override)

    app_override = os.environ.get("MLXTRA_APP_BUNDLE")
    if app_override:
        return Path(app_override) / "Contents/Resources/runtime/macos-arm64"

    runtime_dir = _newest_existing_runtime()
    if runtime_dir:
        return runtime_dir

    repo_runtime = REPO_ROOT / "MLXtra/Resources/runtime/macos-arm64"
    if repo_runtime.exists():
        return repo_runtime

    raise FileNotFoundError(
        "Could not find MLXtra runtime. Build the app with xcodebuild, set "
        "MLXTRA_APP_BUNDLE, or set MLXTRA_RUNTIME_DIR."
    )


RUNTIME_DIR = resolve_runtime_dir()
VENV_SITE_PACKAGES = RUNTIME_DIR / "acestep-venv/lib/python3.12/site-packages"

if str(VENV_SITE_PACKAGES) not in sys.path:
    sys.path.insert(0, str(VENV_SITE_PACKAGES))


def send_json(obj: dict) -> None:
    print(json.dumps(obj, indent=2), flush=True)


def test_model_presence():
    """Test if the model files are actually present where ACE-Step expects them."""
    print("=" * 60)
    print("TEST 1: Checking model presence")
    print("=" * 60)

    from acestep.model_downloader import (
        check_main_model_exists,
        check_model_exists,
        get_checkpoints_dir,
    )

    checkpoints_dir = get_checkpoints_dir()
    print(f"Checkpoints directory: {checkpoints_dir}")
    print(f"Exists: {checkpoints_dir.exists()}")

    if checkpoints_dir.exists():
        print("\nContents:")
        for item in checkpoints_dir.iterdir():
            print(f"  {item.name} - {'dir' if item.is_dir() else 'file'}")
            if item.is_dir():
                sub_items = list(item.iterdir())
                print(f"    ({len(sub_items)} items)")

    main_exists = check_main_model_exists(checkpoints_dir)
    print(f"\nMain model exists: {main_exists}")

    model_id = normalize_music_model_id("ACE-Step/acestep-v15-turbo-continuous")
    dit_exists = check_model_exists(model_id, checkpoints_dir)
    print(f"DiT model '{model_id}' exists: {dit_exists}")

    return main_exists and dit_exists


def test_initialization():
    """Test ACE-Step handler initialization."""
    print("\n" + "=" * 60)
    print("TEST 2: Testing handler initialization")
    print("=" * 60)

    try:
        from acestep.handler import AceStepHandler
        from acestep.llm_inference import LLMHandler

        handler = AceStepHandler()

        import importlib.util

        package_spec = importlib.util.find_spec("acestep")
        project_root = (
            Path(package_spec.origin).parent.parent
            if package_spec and package_spec.origin
            else Path.cwd()
        )

        config_path = normalize_music_model_id("ACE-Step/acestep-v15-turbo-continuous")

        print(f"Project root: {project_root}")
        print(f"Config path: {config_path}")

        print("\nCalling initialize_service()...")
        result = handler.initialize_service(
            project_root=str(project_root),
            config_path=str(config_path),
            device="mps",
        )

        print(f"Initialize result: {result}")

        if result and result[1] is True:
            print("\n✓ Initialization succeeded!")
            print(f"  Model: {type(handler.model)}")
            print(f"  VAE: {type(handler.vae)}")
            print(f"  Text encoder: {type(handler.text_encoder)}")
            print(f"  Text tokenizer: {type(handler.text_tokenizer)}")
            return True
        else:
            print(
                f"\n✗ Initialization failed: {result[0] if result else 'Unknown error'}"
            )
            return False

    except Exception as e:
        print(f"\n✗ Exception during initialization: {e}")
        import traceback

        traceback.print_exc()
        return False


def test_bridge():
    """Test the acestep_bridge module."""
    print("\n" + "=" * 60)
    print("TEST 3: Testing acestep_bridge")
    print("=" * 60)

    bridge_path = Path(__file__).parent / "MLXtra/Resources/acestep_bridge.py"
    if not bridge_path.exists():
        bridge_path = (
            Path(__file__).parent / "MLXtra/MLXtra/Resources/acestep_bridge.py"
        )

    print(f"Bridge script: {bridge_path}")
    print(f"Exists: {bridge_path.exists()}")

    sys.path.insert(0, str(bridge_path.parent))

    try:
        import acestep_bridge

        print("✓ acestep_bridge imported successfully")

        request = {
            "model": "ACE-Step/acestep-v15-turbo-continuous",
            "messages": [{"role": "user", "content": "upbeat electronic dance music"}],
            "parameters": {
                "caption": "upbeat electronic dance music",
                "duration": 10,  # Short for testing
                "inference_steps": 4,  # Fewer steps for testing
            },
        }

        print(f"\nSending request: {json.dumps(request, indent=2)}")
        print("\nGenerating music...")

        acestep_bridge.generate_music_once(request)
        print("\n✓ generate_music_once completed")
        return True

    except Exception as e:
        print(f"\n✗ Exception: {e}")
        import traceback

        traceback.print_exc()
        return False


def main():
    print("ACE-Step Music Generation Test")
    print(f"Python: {sys.version}")
    print(f"Runtime: {RUNTIME_DIR}")

    results = []

    results.append(("Model presence", test_model_presence()))

    results.append(("Initialization", test_initialization()))

    if results[-1][1]:
        results.append(("Bridge", test_bridge()))
    else:
        print("\n⚠ Skipping bridge test due to initialization failure")
        results.append(("Bridge", False))

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for name, passed in results:
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"  {status}: {name}")

    return all(passed for _, passed in results)


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
