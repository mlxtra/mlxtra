#!/bin/bash
set -euo pipefail

if [ "${MLXHUB_SKIP_RUNTIME_VALIDATION:-0}" = "1" ]; then
    echo "Skipping MLXHub runtime validation because MLXHUB_SKIP_RUNTIME_VALIDATION=1"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
RUNTIME_DIR="${PROJECT_DIR}/MLXHub/Resources/runtime/macos-arm64"
PYTHON_HOME="${RUNTIME_DIR}/python/Frameworks/Versions/3.12"
MAIN_PYTHON="${RUNTIME_DIR}/venv/bin/python"
ACE_PYTHON="${RUNTIME_DIR}/acestep-venv/bin/python"
MAIN_SITE_PACKAGES="${RUNTIME_DIR}/venv/lib/python3.12/site-packages"
ACE_SITE_PACKAGES="${RUNTIME_DIR}/acestep-venv/lib/python3.12/site-packages"
MANIFEST="${RUNTIME_DIR}/runtime-manifest.json"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_directory() {
    local path="$1"
    local label="$2"

    [ -d "${path}" ] || fail "${label} is missing at ${path}. Run ./Scripts/build-runtime-bundle.sh before building the app."
}

require_file() {
    local path="$1"
    local label="$2"

    [ -f "${path}" ] || fail "${label} is missing at ${path}. Run ./Scripts/build-runtime-bundle.sh before building the app."
}

require_executable() {
    local path="$1"
    local label="$2"

    [ -x "${path}" ] || fail "${label} is missing or not executable at ${path}. Run ./Scripts/build-runtime-bundle.sh before building the app."
}

require_directory "${RUNTIME_DIR}" "Runtime bundle"
require_directory "${PYTHON_HOME}" "Bundled Python home"
require_executable "${MAIN_PYTHON}" "Main runtime Python"
require_executable "${ACE_PYTHON}" "ACE-Step runtime Python"
require_file "${MANIFEST}" "Runtime manifest"
require_file "${PROJECT_DIR}/MLXHub/Resources/python_bridge.py" "Python bridge"
require_file "${PROJECT_DIR}/MLXHub/Resources/acestep_bridge.py" "ACE-Step bridge"
require_file "${PROJECT_DIR}/MLXHub/Resources/bridge_utils.py" "Bridge utilities"
require_file "${RUNTIME_DIR}/hf_download_helper.py" "Hugging Face download helper"
require_file "${RUNTIME_DIR}/acestep_download_helper.py" "ACE-Step download helper"

validate_manifest() {
    /usr/bin/python3 - "${MANIFEST}" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())

expected_packages = {
    "mlx": "0.31.1",
    "mlx-vlm": "0.4.4",
    "mlx-audio": "0.4.2",
    "mflux": "0.17.5",
    "transformers": "5.5.4",
    "huggingface-hub": "1.10.2",
    "pillow": "12.2.0",
    "numpy": "2.4.4",
    "torch": "2.11.0",
    "torchvision": "0.26.0",
}

manifest_packages = set(manifest.get("packages", []))
for package, version in expected_packages.items():
    pinned = f"{package}=={version}"
    if pinned not in manifest_packages:
        raise SystemExit(f"runtime manifest is missing {pinned}")

expected_backends = {"vlm", "llm", "image", "audio", "music"}
manifest_backends = set(manifest.get("supportedBackends", []))
missing_backends = expected_backends - manifest_backends
if missing_backends:
    raise SystemExit(f"runtime manifest is missing supported backends: {sorted(missing_backends)}")

expected_capabilities = {
    "chat",
    "vision",
    "image-generation",
    "image-editing",
    "speech-generation",
    "music-generation",
}
manifest_capabilities = set(manifest.get("capabilities", []))
missing_capabilities = expected_capabilities - manifest_capabilities
if missing_capabilities:
    raise SystemExit(f"runtime manifest is missing capabilities: {sorted(missing_capabilities)}")
PY
}

validate_runtime_python() {
    PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${MAIN_PYTHON}" - <<'PY'
import _csv
import csv
import importlib.metadata as metadata

expected_packages = {
    "mlx": "0.31.1",
    "mlx-vlm": "0.4.4",
    "mlx-audio": "0.4.2",
    "mflux": "0.17.5",
    "transformers": "5.5.4",
    "huggingface-hub": "1.10.2",
    "pillow": "12.2.0",
    "numpy": "2.4.4",
    "torch": "2.11.0",
    "torchvision": "0.26.0",
}

for package, version in expected_packages.items():
    installed = metadata.version(package)
    if installed != version:
        raise SystemExit(f"{package} version mismatch: expected {version}, got {installed}")

if _csv.__name__ != "_csv" or csv.__name__ != "csv":
    raise SystemExit("bundled Python standard library is incomplete")
PY

    PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${ACE_PYTHON}" - <<'PY'
import importlib.metadata as metadata

metadata.version("ace-step")
PY
}

validate_download_helpers() {
    PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${MAIN_PYTHON}" - <<'PY'
import importlib

for package in ("huggingface_hub", "tqdm"):
    importlib.import_module(package)
PY

    PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${ACE_PYTHON}" - <<'PY'
import importlib

for package in ("huggingface_hub", "tqdm", "acestep"):
    importlib.import_module(package)
PY
}

validate_download_helper_structure() {
    require_directory "${MAIN_SITE_PACKAGES}/huggingface_hub" "Main runtime huggingface_hub package"
    require_directory "${MAIN_SITE_PACKAGES}/tqdm" "Main runtime tqdm package"
    require_directory "${ACE_SITE_PACKAGES}/huggingface_hub" "ACE-Step runtime huggingface_hub package"
    require_directory "${ACE_SITE_PACKAGES}/tqdm" "ACE-Step runtime tqdm package"
    require_directory "${ACE_SITE_PACKAGES}/acestep" "ACE-Step runtime acestep package"
}

validate_manifest

if [ -n "${SCRIPT_INPUT_FILE_COUNT:-}" ]; then
    validate_download_helper_structure
    echo "MLXHub runtime bundle structural and download-helper package validation passed"
    exit 0
fi

validate_download_helper_structure
validate_download_helpers
validate_runtime_python

echo "MLXHub runtime bundle validation passed"
