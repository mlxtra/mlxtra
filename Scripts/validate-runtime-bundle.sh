#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
source "${SCRIPT_DIR}/runtime-dependencies.sh"
RUNTIME_DIR="${PROJECT_DIR}/MLXtra/Resources/runtime/macos-arm64"
PYTHON_HOME="${RUNTIME_DIR}/python/Frameworks/Versions/3.12"
MAIN_PYTHON="${RUNTIME_DIR}/venv/bin/python"
ACE_PYTHON="${RUNTIME_DIR}/acestep-venv/bin/python"
MAIN_SITE_PACKAGES="${RUNTIME_DIR}/venv/lib/python3.12/site-packages"
ACE_SITE_PACKAGES="${RUNTIME_DIR}/acestep-venv/lib/python3.12/site-packages"
MANIFEST="${RUNTIME_DIR}/runtime-manifest.json"
BUILD_RUNTIME_SCRIPT="${SCRIPT_DIR}/build-runtime-bundle.sh"
BOOTSTRAP_RUNTIME_ON_BUILD="${MLXTRA_BOOTSTRAP_RUNTIME_ON_BUILD:-1}"

fail() {
    echo "error: $*" >&2
    exit 1
}

write_validation_stamp() {
    if [ "${SCRIPT_OUTPUT_FILE_COUNT:-0}" -gt 0 ] && [ -n "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        printf 'validated\n' > "${SCRIPT_OUTPUT_FILE_0}"
    fi
}

if [ "${MLXTRA_SKIP_RUNTIME_VALIDATION:-0}" = "1" ]; then
    echo "Skipping MLXtra runtime validation because MLXTRA_SKIP_RUNTIME_VALIDATION=1"
    write_validation_stamp
    exit 0
fi

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

runtime_bootstrap_required() {
    [ -d "${RUNTIME_DIR}" ] || return 0
    [ -d "${PYTHON_HOME}" ] || return 0
    [ -x "${MAIN_PYTHON}" ] || return 0
    [ -x "${ACE_PYTHON}" ] || return 0
    [ -f "${MANIFEST}" ] || return 0
    [ -f "${PROJECT_DIR}/MLXtra/Resources/python_bridge.py" ] || return 0
    [ -f "${PROJECT_DIR}/MLXtra/Resources/acestep_bridge.py" ] || return 0
    [ -f "${PROJECT_DIR}/MLXtra/Resources/bridge_utils.py" ] || return 0
    [ -f "${RUNTIME_DIR}/hf_download_helper.py" ] || return 0
    [ -f "${RUNTIME_DIR}/acestep_download_helper.py" ] || return 0
    return 1
}

bootstrap_runtime_if_needed() {
    runtime_bootstrap_required || return 0

    if [ "${BOOTSTRAP_RUNTIME_ON_BUILD}" != "1" ]; then
        return 0
    fi

    [ -x "${BUILD_RUNTIME_SCRIPT}" ] || fail "Runtime bootstrap script is missing or not executable at ${BUILD_RUNTIME_SCRIPT}."

    echo "warning: MLXtra first build is downloading and creating the local Python runtime. This can take several minutes and requires network access."
    echo "warning: Keep Xcode open. Later builds reuse the generated runtime and skip this step."
    "${BUILD_RUNTIME_SCRIPT}"
    echo "MLXtra runtime bootstrap completed."
}

bootstrap_runtime_if_needed

require_directory "${RUNTIME_DIR}" "Runtime bundle"
require_directory "${PYTHON_HOME}" "Bundled Python home"
require_executable "${MAIN_PYTHON}" "Main runtime Python"
require_executable "${ACE_PYTHON}" "ACE-Step runtime Python"
require_file "${MANIFEST}" "Runtime manifest"
require_file "${PROJECT_DIR}/MLXtra/Resources/python_bridge.py" "Python bridge"
require_file "${PROJECT_DIR}/MLXtra/Resources/acestep_bridge.py" "ACE-Step bridge"
require_file "${PROJECT_DIR}/MLXtra/Resources/bridge_utils.py" "Bridge utilities"
require_file "${RUNTIME_DIR}/hf_download_helper.py" "Hugging Face download helper"
require_file "${RUNTIME_DIR}/acestep_download_helper.py" "ACE-Step download helper"

validate_manifest() {
    RUNTIME_EXPECTED_PACKAGES="$(printf '%s\n' "${RUNTIME_MAIN_PACKAGES[@]}")" \
    RUNTIME_EXPECTED_BACKENDS="$(printf '%s\n' "${RUNTIME_SUPPORTED_BACKENDS[@]}")" \
    RUNTIME_EXPECTED_CAPABILITIES="$(printf '%s\n' "${RUNTIME_CAPABILITIES[@]}")" \
    RUNTIME_EXPECTED_MODELS="$(printf '%s\n' "${RUNTIME_SUPPORTED_MODELS[@]}")" \
    /usr/bin/python3 - "${MANIFEST}" <<'PY'
import json
import os
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())

expected_packages = set(os.environ["RUNTIME_EXPECTED_PACKAGES"].splitlines())

manifest_packages = set(manifest.get("packages", []))
missing_packages = expected_packages - manifest_packages
if missing_packages:
    raise SystemExit(f"runtime manifest is missing packages: {sorted(missing_packages)}")

expected_backends = set(os.environ["RUNTIME_EXPECTED_BACKENDS"].splitlines())
manifest_backends = set(manifest.get("supportedBackends", []))
missing_backends = expected_backends - manifest_backends
if missing_backends:
    raise SystemExit(f"runtime manifest is missing supported backends: {sorted(missing_backends)}")

expected_capabilities = set(os.environ["RUNTIME_EXPECTED_CAPABILITIES"].splitlines())
manifest_capabilities = set(manifest.get("capabilities", []))
missing_capabilities = expected_capabilities - manifest_capabilities
if missing_capabilities:
    raise SystemExit(f"runtime manifest is missing capabilities: {sorted(missing_capabilities)}")

expected_models = set(os.environ["RUNTIME_EXPECTED_MODELS"].splitlines())
manifest_models = set(manifest.get("supportedModels", []))
missing_models = expected_models - manifest_models
if missing_models:
    raise SystemExit(f"runtime manifest is missing supported models: {sorted(missing_models)}")
PY
}

validate_runtime_python() {
    RUNTIME_EXPECTED_PACKAGES="$(printf '%s\n' "${RUNTIME_MAIN_PACKAGES[@]}")" \
    PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${MAIN_PYTHON}" - <<'PY'
import _csv
import csv
import importlib.metadata as metadata
import os

expected_packages = {}
for pinned in os.environ["RUNTIME_EXPECTED_PACKAGES"].splitlines():
    package, version = pinned.split("==", 1)
    expected_packages[package] = version

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
    write_validation_stamp
    echo "MLXtra runtime bundle structural and download-helper package validation passed"
    exit 0
fi

validate_download_helper_structure
validate_download_helpers
validate_runtime_python
write_validation_stamp

echo "MLXtra runtime bundle validation passed"
