#!/usr/bin/env python3
"""Test script for Python bridge"""

import sys
import json
import os
from pathlib import Path

# Setup environment
bundle_dir = Path(__file__).parent
venv_path = bundle_dir / "MLXtra" / "Resources" / "runtime" / "macos-arm64" / "venv"

if venv_path.exists():
    for py_version in ["python3.13", "python3.12", "python3.11"]:
        site_packages = venv_path / "lib" / py_version / "site-packages"
        if site_packages.exists():
            sys.path.insert(0, str(site_packages))
            print(f"Added {site_packages} to path")
            break

# Test imports
try:
    import mlx

    print("OK: mlx imported successfully")

    from mlx_vlm import load

    print("OK: mlx_vlm imported successfully")

    import mflux

    print("OK: mflux imported successfully")

    print("\nBridge test successful!")
    print(f"Python version: {sys.version}")

except Exception as e:
    print(f"ERROR: {e}")
    import traceback

    traceback.print_exc()
    sys.exit(1)

sys.exit(0)
