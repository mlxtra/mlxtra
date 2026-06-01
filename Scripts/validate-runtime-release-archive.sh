#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/runtime-dependencies.sh"

ARCHIVE_PATH=""
EXPECTED_VERSION=""
EXPECTED_COMPATIBILITY_API=""
COMPONENT="base"
BASE_RUNTIME_DIR=""
RUN_IMPORT_SMOKE=1
RUN_METAL_SMOKE=0
KEEP_EXTRACTED=0

usage() {
    cat <<'USAGE'
Usage: Scripts/validate-runtime-release-archive.sh [options] runtime-macos-arm64-<version>.zip

Validates the exact distributable runtime archive before it is published.
The archive is extracted with ditto and checked with the same structural
requirements used by the app's runtime installer.

Options:
  --component base|music                 Archive component to validate. Default: base.
  --base-runtime-dir path                Installed base runtime root for music import checks.
  --expected-version version             Require runtime-manifest.json runtimeVersion.
  --expected-compatibility-api number    Require runtime-manifest.json compatibilityApi.
  --skip-import-smoke                    Skip extracted Python import checks.
  --metal-smoke                          Run a small MLX array operation in both venvs.
  --keep-extracted                       Keep the extracted temporary directory for debugging.
  -h, --help                             Show this help.
USAGE
}

require_option_value() {
    local option="$1"
    local value="${2:-}"

    if [ -z "${value}" ] || [[ "${value}" == --* ]]; then
        echo "${option} requires a value." >&2
        usage >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --expected-version)
            require_option_value "$1" "${2:-}"
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --component)
            require_option_value "$1" "${2:-}"
            COMPONENT="$2"
            shift 2
            ;;
        --base-runtime-dir)
            require_option_value "$1" "${2:-}"
            BASE_RUNTIME_DIR="$2"
            shift 2
            ;;
        --expected-compatibility-api)
            require_option_value "$1" "${2:-}"
            EXPECTED_COMPATIBILITY_API="$2"
            shift 2
            ;;
        --skip-import-smoke)
            RUN_IMPORT_SMOKE=0
            shift
            ;;
        --metal-smoke)
            RUN_METAL_SMOKE=1
            shift
            ;;
        --keep-extracted)
            KEEP_EXTRACTED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -n "${ARCHIVE_PATH}" ]; then
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 2
            fi
            ARCHIVE_PATH="$1"
            shift
            ;;
    esac
done

if [ -z "${ARCHIVE_PATH}" ]; then
    echo "Missing runtime archive path." >&2
    usage >&2
    exit 2
fi

if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "Runtime archive does not exist: ${ARCHIVE_PATH}" >&2
    exit 1
fi

if [ "${COMPONENT}" != "base" ] && [ "${COMPONENT}" != "music" ]; then
    echo "--component must be base or music" >&2
    exit 2
fi

if [ "${COMPONENT}" = "music" ] && [ "${RUN_IMPORT_SMOKE}" = "1" ] && [ -z "${BASE_RUNTIME_DIR}" ]; then
    echo "--component music import checks require --base-runtime-dir" >&2
    exit 2
fi

if ! command -v zipinfo >/dev/null 2>&1; then
    echo "Missing required command: zipinfo" >&2
    exit 1
fi

if [ "${RUN_IMPORT_SMOKE}" = "0" ] && [ "${RUN_METAL_SMOKE}" = "1" ]; then
    echo "--metal-smoke requires import smoke checks." >&2
    exit 2
fi

ARCHIVE_PATH="$(cd "$(dirname "${ARCHIVE_PATH}")" && pwd -P)/$(basename "${ARCHIVE_PATH}")"
EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mlxtra-runtime-archive.XXXXXX")"

cleanup() {
    if [ "${KEEP_EXTRACTED}" = "1" ]; then
        echo "Kept extracted runtime archive at ${EXTRACT_ROOT}"
    else
        rm -rf "${EXTRACT_ROOT}"
    fi
}
trap cleanup EXIT

echo "Validating runtime archive: ${ARCHIVE_PATH}"

ZIP_ENTRY_LIST="${EXTRACT_ROOT}/zip-entries.txt"
zipinfo -1 "${ARCHIVE_PATH}" > "${ZIP_ENTRY_LIST}"

/usr/bin/python3 - "${ZIP_ENTRY_LIST}" <<'PY'
import sys

bad_entries = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    entries = list(handle)

for raw in entries:
    entry = raw.rstrip("\n")
    if not entry:
        bad_entries.append("<empty entry>")
        continue
    if entry.startswith("/") or entry.startswith("__MACOSX/") or "/._" in entry or entry.startswith("._"):
        bad_entries.append(entry)
        continue
    if any(component == ".." for component in entry.split("/")):
        bad_entries.append(entry)

if bad_entries:
    print("Runtime archive contains unsafe or macOS metadata entries:", file=sys.stderr)
    for entry in bad_entries[:50]:
        print(f"  {entry}", file=sys.stderr)
    if len(bad_entries) > 50:
        print(f"  ... and {len(bad_entries) - 50} more", file=sys.stderr)
    raise SystemExit(1)
PY

/usr/bin/ditto -x -k "${ARCHIVE_PATH}" "${EXTRACT_ROOT}/extract"

copy_runtime_tree() {
    local source_dir="$1"
    local destination_dir="$2"

    /usr/bin/python3 - "${source_dir}" "${destination_dir}" <<'PY'
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])


def ignored(_directory, names):
    return {
        name
        for name in names
        if name in {".DS_Store", "Icon\r"} or name.startswith("._")
    }


if destination.exists() or destination.is_symlink():
    if destination.is_dir() and not destination.is_symlink():
        shutil.rmtree(destination)
    else:
        destination.unlink()

destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(source, destination, symlinks=True, ignore=ignored)
PY
}

RUNTIME_ROOT="$(
    EXPECTED_VERSION="${EXPECTED_VERSION}" \
    EXPECTED_COMPATIBILITY_API="${EXPECTED_COMPATIBILITY_API}" \
    EXPECTED_MLX_WHEEL_PLATFORM="${RUNTIME_MLX_WHEEL_PLATFORM}" \
    COMPONENT="${COMPONENT}" \
    /usr/bin/python3 - "${EXTRACT_ROOT}/extract" <<'PY'
import json
import os
import pathlib
import sys

extract_root = pathlib.Path(sys.argv[1])
expected_version = os.environ.get("EXPECTED_VERSION") or None
expected_compatibility_api = os.environ.get("EXPECTED_COMPATIBILITY_API") or None
expected_mlx_wheel_platform = os.environ["EXPECTED_MLX_WHEEL_PLATFORM"]
component = os.environ["COMPONENT"]

if component == "base":
    manifest_name = "runtime-manifest.json"
    required_paths = [
        "venv/bin/python",
        "python/Frameworks/Versions/3.12",
        manifest_name,
    ]
    required_executables = [
        "venv/bin/python",
    ]
    wheel_site_packages = [
        "venv/lib/python3.12/site-packages",
    ]
else:
    manifest_name = "runtime-music-manifest.json"
    required_paths = [
        "acestep-venv/bin/python",
        "acestep_download_helper.py",
        manifest_name,
    ]
    required_executables = [
        "acestep-venv/bin/python",
    ]
    wheel_site_packages = []


def load_manifest(root):
    manifest_path = root / manifest_name
    if not manifest_path.is_file():
        return None
    try:
        return json.loads(manifest_path.read_text())
    except json.JSONDecodeError:
        return None


def structurally_valid(root):
    manifest = load_manifest(root)
    if manifest is None:
        return False
    return all((root / rel).exists() for rel in required_paths)


def normalized_runtime_root():
    if structurally_valid(extract_root):
        return extract_root
    children = sorted(child for child in extract_root.iterdir() if child.is_dir())
    for child in children:
        if structurally_valid(child):
            return child
    raise SystemExit("No structurally valid runtime root found after extraction")


runtime_root = normalized_runtime_root()
manifest = load_manifest(runtime_root)
if manifest is None:
    raise SystemExit("Extracted runtime manifest is missing or invalid JSON")

if manifest.get("component", "base") != component:
    raise SystemExit(
        f"Runtime component mismatch: expected {component}, got {manifest.get('component', 'base')}"
    )

if expected_version and manifest.get("runtimeVersion") != expected_version:
    raise SystemExit(
        f"Runtime version mismatch: expected {expected_version}, got {manifest.get('runtimeVersion')}"
    )

if expected_compatibility_api:
    actual_api = manifest.get("compatibilityApi")
    if str(actual_api) != expected_compatibility_api:
        raise SystemExit(
            f"Runtime compatibilityApi mismatch: expected {expected_compatibility_api}, got {actual_api}"
        )

missing = [rel for rel in required_paths if not (runtime_root / rel).exists()]
if missing:
    raise SystemExit(f"Extracted runtime is missing required paths: {missing}")

not_executable = [rel for rel in required_executables if not os.access(runtime_root / rel, os.X_OK)]
if not_executable:
    raise SystemExit(f"Extracted runtime has non-executable required files: {not_executable}")

root_resolved = runtime_root.resolve()
escaping_symlinks = []
for path in runtime_root.rglob("*"):
    if not path.is_symlink():
        continue
    resolved = path.resolve(strict=False)
    try:
        resolved.relative_to(root_resolved)
    except ValueError:
        escaping_symlinks.append((str(path.relative_to(runtime_root)), str(resolved)))

if escaping_symlinks:
    print("Extracted runtime contains symlinks that point outside the bundle:", file=sys.stderr)
    for path, resolved in escaping_symlinks[:50]:
        print(f"  {path} -> {resolved}", file=sys.stderr)
    if len(escaping_symlinks) > 50:
        print(f"  ... and {len(escaping_symlinks) - 50} more", file=sys.stderr)
    raise SystemExit(1)


def validate_wheel_tag(site_packages, wheel_stem):
    wheel_files = sorted(site_packages.glob(f"{wheel_stem}-*.dist-info/WHEEL"))
    if not wheel_files:
        raise SystemExit(f"{wheel_stem} WHEEL metadata not found in {site_packages}")
    tags = [
        line.removeprefix("Tag: ").strip()
        for line in wheel_files[-1].read_text().splitlines()
        if line.startswith("Tag: ")
    ]
    if not any(expected_mlx_wheel_platform in tag for tag in tags):
        raise SystemExit(
            f"{wheel_stem} is not using {expected_mlx_wheel_platform}; found tags: {tags}"
        )


for relative_site_packages in wheel_site_packages:
    site_packages = runtime_root / relative_site_packages
    validate_wheel_tag(site_packages, "mlx")
    validate_wheel_tag(site_packages, "mlx_metal")

print(runtime_root)
PY
)"

if [ "${COMPONENT}" = "music" ]; then
    BASE_RUNTIME_DIR="$(cd "${BASE_RUNTIME_DIR}" && pwd -P)"
    OVERLAY_ROOT="${EXTRACT_ROOT}/installed-base-overlay"
    copy_runtime_tree "${BASE_RUNTIME_DIR}" "${OVERLAY_ROOT}"
    rm -rf \
        "${OVERLAY_ROOT}/acestep-venv" \
        "${OVERLAY_ROOT}/acestep_download_helper.py" \
        "${OVERLAY_ROOT}/runtime-music-manifest.json"
    copy_runtime_tree "${RUNTIME_ROOT}/acestep-venv" "${OVERLAY_ROOT}/acestep-venv"
    cp "${RUNTIME_ROOT}/acestep_download_helper.py" "${OVERLAY_ROOT}/acestep_download_helper.py"
    cp "${RUNTIME_ROOT}/runtime-music-manifest.json" "${OVERLAY_ROOT}/runtime-music-manifest.json"
    RUNTIME_ROOT="${OVERLAY_ROOT}"
fi

PYTHON_HOME="${RUNTIME_ROOT}/python/Frameworks/Versions/3.12"

if [ "${RUN_IMPORT_SMOKE}" = "1" ]; then
    if [ "${COMPONENT}" = "base" ]; then
        PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${RUNTIME_ROOT}/venv/bin/python" - <<'PY'
import csv
import importlib.metadata as metadata

for package in ("mlx", "mlx-metal", "mlx-vlm"):
    metadata.version(package)

if csv.__name__ != "csv":
    raise SystemExit("bundled Python standard library import failed")
PY
    fi

    if [ "${COMPONENT}" = "music" ]; then
        PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${RUNTIME_ROOT}/acestep-venv/bin/python" - <<'PY'
import importlib.metadata as metadata
from acestep.inference import GenerationConfig

for package in ("ace-step", "mlx", "mlx-metal"):
    metadata.version(package)

if GenerationConfig is None:
    raise SystemExit("ACE-Step import failed")
PY
    fi
fi

if [ "${RUN_METAL_SMOKE}" = "1" ]; then
    if [ "${COMPONENT}" = "base" ]; then
        PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${RUNTIME_ROOT}/venv/bin/python" - <<'PY'
import mlx.core as mx

if (mx.array([1, 2, 3]) + 1).tolist() != [2, 3, 4]:
    raise SystemExit("Main MLX Metal smoke failed")
PY
    fi

    if [ "${COMPONENT}" = "music" ]; then
        PYTHONHOME="${PYTHON_HOME}" PYTHONDONTWRITEBYTECODE=1 "${RUNTIME_ROOT}/acestep-venv/bin/python" - <<'PY'
import mlx.core as mx

if (mx.array([1, 2, 3]) + 1).tolist() != [2, 3, 4]:
    raise SystemExit("ACE-Step MLX Metal smoke failed")
PY
    fi
fi

echo "Runtime release archive validation passed"
