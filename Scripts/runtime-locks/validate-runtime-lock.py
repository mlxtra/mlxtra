#!/usr/bin/env python3
"""Generate and validate the checked runtime dependency lock."""

from __future__ import annotations

import argparse
import difflib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
DEFAULT_DEPENDENCIES = SCRIPTS_DIR / "runtime-dependencies.sh"
DEFAULT_LOCK_FILE = SCRIPTS_DIR / "runtime-locks/macos-arm64.lock.json"

SCALAR_NAMES = (
    "RUNTIME_VERSION",
    "PYTHON_VERSION",
    "PYTHON_URL",
    "PYTHON_PKG_NAME",
    "PYTHON_PKG_SHA256",
    "MLX_VERSION",
    "MLX_METAL_VERSION",
    "MLX_VLM_VERSION",
    "MLX_AUDIO_VERSION",
    "MISAKI_VERSION",
    "MFLUX_VERSION",
    "MFLUX_REF",
    "MFLUX_PACKAGE",
    "TRANSFORMERS_VERSION",
    "HUGGINGFACE_HUB_VERSION",
    "PILLOW_VERSION",
    "NUMPY_VERSION",
    "TORCH_VERSION",
    "TORCHVISION_VERSION",
    "ACE_STEP_REF",
    "ACE_STEP_PACKAGE",
    "MAGENTA_RT_VERSION",
    "MAGENTA_RT_PACKAGE",
    "RUNTIME_MLX_WHEEL_PLATFORM",
)

ARRAY_NAMES = (
    "RUNTIME_FORCED_BINARY_PYPI_PACKAGES",
    "RUNTIME_MAIN_PYPI_PACKAGES",
    "RUNTIME_MAIN_INSTALL_PACKAGES",
    "RUNTIME_TORCH_PACKAGES",
    "RUNTIME_MAIN_PACKAGES",
)

BASH_EXPORT_SCRIPT = r"""
set -euo pipefail
source "${RUNTIME_DEPENDENCIES_PATH:?}"

scalar_names=(
    RUNTIME_VERSION
    PYTHON_VERSION
    PYTHON_URL
    PYTHON_PKG_NAME
    PYTHON_PKG_SHA256
    MLX_VERSION
    MLX_METAL_VERSION
    MLX_VLM_VERSION
    MLX_AUDIO_VERSION
    MISAKI_VERSION
    MFLUX_VERSION
    MFLUX_REF
    MFLUX_PACKAGE
    TRANSFORMERS_VERSION
    HUGGINGFACE_HUB_VERSION
    PILLOW_VERSION
    NUMPY_VERSION
    TORCH_VERSION
    TORCHVISION_VERSION
    ACE_STEP_REF
    ACE_STEP_PACKAGE
    MAGENTA_RT_VERSION
    MAGENTA_RT_PACKAGE
    RUNTIME_MLX_WHEEL_PLATFORM
)

array_names=(
    RUNTIME_FORCED_BINARY_PYPI_PACKAGES
    RUNTIME_MAIN_PYPI_PACKAGES
    RUNTIME_MAIN_INSTALL_PACKAGES
    RUNTIME_TORCH_PACKAGES
    RUNTIME_MAIN_PACKAGES
)

for name in "${scalar_names[@]}"; do
    printf 'scalar\0%s\0%s\0' "${name}" "${!name}"
done

for name in "${array_names[@]}"; do
    eval "values=(\"\${${name}[@]}\")"
    printf 'array\0%s\0%s\0' "${name}" "${#values[@]}"
    for value in "${values[@]}"; do
        printf '%s\0' "${value}"
    done
done
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate Scripts/runtime-locks/macos-arm64.lock.json against runtime-dependencies.sh.",
    )
    parser.add_argument(
        "--dependencies",
        type=Path,
        default=DEFAULT_DEPENDENCIES,
        help=f"runtime dependency pin script. Default: {DEFAULT_DEPENDENCIES}",
    )
    parser.add_argument(
        "--lock-file",
        type=Path,
        default=DEFAULT_LOCK_FILE,
        help=f"runtime dependency lock file. Default: {DEFAULT_LOCK_FILE}",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--write",
        action="store_true",
        help="rewrite the lock file with the generated canonical content",
    )
    mode.add_argument(
        "--print",
        dest="print_lock",
        action="store_true",
        help="print the generated canonical lock content",
    )
    return parser.parse_args()


def load_runtime_dependency_values(dependencies: Path) -> dict[str, Any]:
    env = os.environ.copy()
    env["RUNTIME_DEPENDENCIES_PATH"] = str(dependencies)
    result = subprocess.run(
        ["bash", "-c", BASH_EXPORT_SCRIPT],
        check=True,
        capture_output=True,
        env=env,
    )
    fields = result.stdout.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()

    values: dict[str, Any] = {}
    index = 0
    while index < len(fields):
        kind = fields[index].decode("utf-8")
        index += 1
        if kind == "scalar":
            name = fields[index].decode("utf-8")
            value = fields[index + 1].decode("utf-8")
            index += 2
            values[name] = value
        elif kind == "array":
            name = fields[index].decode("utf-8")
            count = int(fields[index + 1].decode("utf-8"))
            index += 2
            items = [
                fields[index + offset].decode("utf-8")
                for offset in range(count)
            ]
            index += count
            values[name] = items
        else:
            raise RuntimeError(f"unexpected field kind from bash export: {kind!r}")

    missing_scalars = sorted(set(SCALAR_NAMES) - values.keys())
    missing_arrays = sorted(set(ARRAY_NAMES) - values.keys())
    if missing_scalars or missing_arrays:
        raise RuntimeError(
            "runtime dependency export did not include all expected fields: "
            f"scalars={missing_scalars}, arrays={missing_arrays}"
        )

    return values


def build_lock(values: dict[str, Any]) -> dict[str, Any]:
    return {
        "lockVersion": 1,
        "runtime": {
            "version": values["RUNTIME_VERSION"],
            "pythonVersion": values["PYTHON_VERSION"],
            "mlxWheelPlatform": values["RUNTIME_MLX_WHEEL_PLATFORM"],
        },
        "pythonPackage": {
            "url": values["PYTHON_URL"],
            "name": values["PYTHON_PKG_NAME"],
            "sha256": values["PYTHON_PKG_SHA256"],
        },
        "pins": {
            "MLX_VERSION": values["MLX_VERSION"],
            "MLX_METAL_VERSION": values["MLX_METAL_VERSION"],
            "MLX_VLM_VERSION": values["MLX_VLM_VERSION"],
            "MLX_AUDIO_VERSION": values["MLX_AUDIO_VERSION"],
            "MISAKI_VERSION": values["MISAKI_VERSION"],
            "MFLUX_VERSION": values["MFLUX_VERSION"],
            "MFLUX_REF": values["MFLUX_REF"],
            "TRANSFORMERS_VERSION": values["TRANSFORMERS_VERSION"],
            "HUGGINGFACE_HUB_VERSION": values["HUGGINGFACE_HUB_VERSION"],
            "PILLOW_VERSION": values["PILLOW_VERSION"],
            "NUMPY_VERSION": values["NUMPY_VERSION"],
            "TORCH_VERSION": values["TORCH_VERSION"],
            "TORCHVISION_VERSION": values["TORCHVISION_VERSION"],
            "ACE_STEP_REF": values["ACE_STEP_REF"],
            "MAGENTA_RT_VERSION": values["MAGENTA_RT_VERSION"],
        },
        "packages": {
            "forcedBinaryPyPI": values["RUNTIME_FORCED_BINARY_PYPI_PACKAGES"],
            "mainPyPI": values["RUNTIME_MAIN_PYPI_PACKAGES"],
            "mainInstall": values["RUNTIME_MAIN_INSTALL_PACKAGES"],
            "torch": values["RUNTIME_TORCH_PACKAGES"],
            "main": values["RUNTIME_MAIN_PACKAGES"],
        },
        "isolatedPackages": {
            "aceStep": {
                "ref": values["ACE_STEP_REF"],
                "package": values["ACE_STEP_PACKAGE"],
            },
            "magentaRealtime": {
                "version": values["MAGENTA_RT_VERSION"],
                "package": values["MAGENTA_RT_PACKAGE"],
            }
        },
        "sourcePackages": {
            "mflux": {
                "ref": values["MFLUX_REF"],
                "package": values["MFLUX_PACKAGE"],
            }
        },
    }


def canonical_json(lock: dict[str, Any]) -> str:
    return json.dumps(lock, indent=2) + "\n"


def validate_lock(lock_file: Path, expected_content: str) -> int:
    if not lock_file.exists():
        print(
            f"runtime dependency lock is missing at {lock_file}. "
            "Regenerate it with: python3 Scripts/runtime-locks/validate-runtime-lock.py --write",
            file=sys.stderr,
        )
        return 1

    actual_content = lock_file.read_text(encoding="utf-8")
    if actual_content == expected_content:
        return 0

    diff = difflib.unified_diff(
        actual_content.splitlines(keepends=True),
        expected_content.splitlines(keepends=True),
        fromfile=str(lock_file),
        tofile="generated from Scripts/runtime-dependencies.sh",
    )
    print(
        "runtime dependency lock is out of date. "
        "Regenerate it with: python3 Scripts/runtime-locks/validate-runtime-lock.py --write",
        file=sys.stderr,
    )
    print("".join(diff), file=sys.stderr, end="")
    return 1


def main() -> int:
    args = parse_args()
    values = load_runtime_dependency_values(args.dependencies)
    expected_content = canonical_json(build_lock(values))

    if args.print_lock:
        print(expected_content, end="")
        return 0

    if args.write:
        args.lock_file.parent.mkdir(parents=True, exist_ok=True)
        args.lock_file.write_text(expected_content, encoding="utf-8")
        print(f"updated {args.lock_file}")
        return 0

    return validate_lock(args.lock_file, expected_content)


if __name__ == "__main__":
    raise SystemExit(main())
