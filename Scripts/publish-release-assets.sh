#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

REPOSITORY="mlxtra/mlxtra"
CHANNEL="stable"
OUTPUT_DIR="${PROJECT_DIR}/.build/release"
SKIP_RUNTIME_ARCHIVE=0
WRITE_CHANNEL=0
FORCE_IMMUTABLE=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: Scripts/publish-release-assets.sh [options]

Prepare release assets and publish the GitHub release metadata needed by
MLXtra's remote catalog/runtime update flow.

The script creates or updates:
  - catalog-<version> release with model-catalog.json
  - runtime-<version> release with runtime-macos-arm64-<version>.zip and legal files
  - stable release with stable-channel.json as the moving channel pointer

Options:
  --repo owner/name          GitHub repository. Default: mlxtra/mlxtra
  --channel name             Stable channel/release tag. Default: stable
  --output-dir path          Release asset staging directory. Default: .build/release
  --skip-runtime-archive     Reuse the runtime entry already present in stable-channel.json
  --write-channel            Also update MLXtra/Resources/stable-channel.json locally
  --force-immutable          Replace assets on catalog/runtime releases if they already exist
  --dry-run                  Print publishing commands without running GitHub write operations
  -h, --help                 Show this help.

Prerequisites:
  - gh CLI installed and authenticated with release write access
  - runtime bundle already built when publishing a new runtime archive
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
        --repo)
            require_option_value "$1" "${2:-}"
            REPOSITORY="$2"
            shift 2
            ;;
        --channel)
            require_option_value "$1" "${2:-}"
            CHANNEL="$2"
            shift 2
            ;;
        --output-dir)
            require_option_value "$1" "${2:-}"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-runtime-archive)
            SKIP_RUNTIME_ARCHIVE=1
            shift
            ;;
        --write-channel)
            WRITE_CHANNEL=1
            shift
            ;;
        --force-immutable)
            FORCE_IMMUTABLE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

json_value() {
    local path="$1"
    local key_path="$2"
    /usr/bin/python3 - "$path" "$key_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    value = json.load(handle)

for key in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(key)]
    else:
        value = value[key]

if value is not None:
    print(value)
PY
}

optional_json_value() {
    local path="$1"
    local key_path="$2"
    /usr/bin/python3 - "$path" "$key_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        value = json.load(handle)

    for key in sys.argv[2].split("."):
        if isinstance(value, list):
            value = value[int(key)]
        else:
            value = value[key]
except (FileNotFoundError, KeyError, IndexError, ValueError, TypeError):
    value = None

if value is not None:
    print(value)
PY
}

run_gh_write() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if [ "${DRY_RUN}" = "0" ]; then
        "$@"
    fi
}

release_exists() {
    local tag="$1"
    [ "${DRY_RUN}" = "0" ] || return 1
    gh release view "${tag}" --repo "${REPOSITORY}" >/dev/null 2>&1
}

release_asset_exists() {
    local tag="$1"
    local asset_name="$2"
    [ "${DRY_RUN}" = "0" ] || return 1
    gh release view "${tag}" --repo "${REPOSITORY}" --json assets -q '.assets[].name' 2>/dev/null \
        | grep -Fxq "${asset_name}"
}

ensure_release() {
    local tag="$1"
    local title="$2"
    local notes="$3"
    local latest_flag="$4"

    if release_exists "${tag}"; then
        if [ "${latest_flag}" = "1" ]; then
            run_gh_write gh release edit "${tag}" \
                --repo "${REPOSITORY}" \
                --title "${title}" \
                --notes "${notes}" \
                --latest
        fi
        return
    fi

    local latest_arg="--latest=false"
    if [ "${latest_flag}" = "1" ]; then
        latest_arg="--latest"
    fi

    run_gh_write gh release create "${tag}" \
        --repo "${REPOSITORY}" \
        --title "${title}" \
        --notes "${notes}" \
        "${latest_arg}"
}

upload_immutable_asset() {
    local tag="$1"
    local path="$2"
    local asset_name
    asset_name="$(basename "${path}")"

    if [ ! -f "${path}" ]; then
        echo "Missing asset: ${path}" >&2
        exit 1
    fi

    if release_asset_exists "${tag}" "${asset_name}"; then
        if [ "${FORCE_IMMUTABLE}" = "0" ]; then
            echo "Asset ${asset_name} already exists on ${tag}." >&2
            echo "Catalog/runtime releases are treated as immutable; pass --force-immutable to replace it." >&2
            exit 1
        fi
        run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}" --clobber
    else
        run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}"
    fi
}

upload_stable_asset() {
    local tag="$1"
    local path="$2"

    if [ ! -f "${path}" ]; then
        echo "Missing stable channel asset: ${path}" >&2
        exit 1
    fi

    run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}" --clobber
}

verify_remote_asset_exists() {
    local tag="$1"
    local asset_name="$2"

    if [ "${DRY_RUN}" = "1" ]; then
        return
    fi

    if ! release_asset_exists "${tag}" "${asset_name}"; then
        echo "Expected ${asset_name} to already exist on ${tag}, but it was not found." >&2
        echo "Re-run without --skip-runtime-archive, or publish that runtime asset first." >&2
        exit 1
    fi
}

require_command gh
require_command /usr/bin/python3

PREPARE_ARGS=(
    "${SCRIPT_DIR}/prepare-release-assets.sh"
    --repo "${REPOSITORY}"
    --channel "${CHANNEL}"
    --output-dir "${OUTPUT_DIR}"
)

if [ "${SKIP_RUNTIME_ARCHIVE}" = "1" ]; then
    PREPARE_ARGS+=(--skip-runtime-archive)
fi

if [ "${WRITE_CHANNEL}" = "1" ]; then
    PREPARE_ARGS+=(--write-channel)
fi

"${PREPARE_ARGS[@]}"

CHANNEL_ASSET="${OUTPUT_DIR}/stable-channel.json"
CATALOG_ASSET="${OUTPUT_DIR}/model-catalog.json"
CATALOG_VERSION="$(json_value "${CHANNEL_ASSET}" "catalog.version")"
CATALOG_TAG="catalog-${CATALOG_VERSION}"
STABLE_TAG="${CHANNEL}"
RUNTIME_VERSION="$(optional_json_value "${CHANNEL_ASSET}" "runtimes.0.version")"
RUNTIME_ARCHIVE=""
RUNTIME_TAG=""

echo ""
echo "Publishing release assets to ${REPOSITORY}"

ensure_release \
    "${CATALOG_TAG}" \
    "Model Catalog ${CATALOG_VERSION}" \
    "Immutable MLXtra model catalog asset ${CATALOG_VERSION}." \
    "0"
upload_immutable_asset "${CATALOG_TAG}" "${CATALOG_ASSET}"

if [ -n "${RUNTIME_VERSION}" ]; then
    RUNTIME_TAG="runtime-${RUNTIME_VERSION}"
    RUNTIME_ARCHIVE="${OUTPUT_DIR}/runtime-macos-arm64-${RUNTIME_VERSION}.zip"
    if [ -f "${RUNTIME_ARCHIVE}" ]; then
        ensure_release \
            "${RUNTIME_TAG}" \
            "Runtime ${RUNTIME_VERSION}" \
            "Immutable MLXtra macOS arm64 runtime asset ${RUNTIME_VERSION}." \
            "0"
        upload_immutable_asset "${RUNTIME_TAG}" "${RUNTIME_ARCHIVE}"
        upload_immutable_asset "${RUNTIME_TAG}" "${OUTPUT_DIR}/LICENSE"
        upload_immutable_asset "${RUNTIME_TAG}" "${OUTPUT_DIR}/NOTICE"
        upload_immutable_asset "${RUNTIME_TAG}" "${OUTPUT_DIR}/THIRD_PARTY_NOTICES.md"
    else
        verify_remote_asset_exists "${RUNTIME_TAG}" "runtime-macos-arm64-${RUNTIME_VERSION}.zip"
        echo "Runtime archive not staged; verified existing runtime asset on ${RUNTIME_TAG}."
    fi
else
    echo "No runtime entry in ${CHANNEL_ASSET}; publishing catalog-only stable channel."
fi

ensure_release \
    "${STABLE_TAG}" \
    "Stable Channel" \
    "Moving MLXtra stable channel pointer. Immutable catalog and runtime assets live on catalog-* and runtime-* releases." \
    "1"
upload_stable_asset "${STABLE_TAG}" "${CHANNEL_ASSET}"
run_gh_write gh release edit "${STABLE_TAG}" --repo "${REPOSITORY}" --latest

echo ""
echo "Published release channel:"
echo "  https://github.com/${REPOSITORY}/releases/download/${STABLE_TAG}/stable-channel.json"
echo ""
echo "Immutable release tags:"
echo "  ${CATALOG_TAG}"
if [ -n "${RUNTIME_TAG}" ]; then
    echo "  ${RUNTIME_TAG}"
fi
