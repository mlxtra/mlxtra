#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

REPOSITORY="kimistudio/MLXHub"
CHANNEL="stable"
OUTPUT_DIR="${PROJECT_DIR}/.build/release"
CATALOG_PATH="${PROJECT_DIR}/MLXHub/Resources/model-catalog.json"
CHANNEL_PATH="${PROJECT_DIR}/MLXHub/Resources/stable-channel.json"
RUNTIME_DIR="${PROJECT_DIR}/MLXHub/Resources/runtime/macos-arm64"
RUNTIME_MANIFEST="${RUNTIME_DIR}/runtime-manifest.json"
SKIP_RUNTIME_ARCHIVE=0
WRITE_CHANNEL=0
CATALOG_VERSION=""
RUNTIME_VERSION=""

usage() {
    cat <<'USAGE'
Usage: Scripts/prepare-release-assets.sh [options]

Build local release assets and generate a stable-channel.json candidate.

Options:
  --repo owner/name              GitHub repository for release URLs. Default: kimistudio/MLXHub
  --channel name                 Release channel name. Default: stable
  --output-dir path              Directory for generated assets. Default: .build/release
  --catalog-version version      Override catalog version. Default: model-catalog.json catalogVersion
  --runtime-version version      Override runtime version. Default: runtime-manifest.json runtimeVersion
  --skip-runtime-archive         Do not zip the runtime. Keeps existing runtime SHA/size from stable-channel.json.
  --write-channel                Replace MLXHub/Resources/stable-channel.json with the generated channel file.
  -h, --help                     Show this help.

The runtime installer currently supports zip assets only, so this script emits
runtime-macos-arm64-<version>.zip.
USAGE
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

if value is None:
    print("")
else:
    print(value)
PY
}

file_size() {
    local path="$1"
    if stat -f%z "$path" >/dev/null 2>&1; then
        stat -f%z "$path"
    else
        stat -c%s "$path"
    fi
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            REPOSITORY="$2"
            shift 2
            ;;
        --channel)
            CHANNEL="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --catalog-version)
            CATALOG_VERSION="$2"
            shift 2
            ;;
        --runtime-version)
            RUNTIME_VERSION="$2"
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

if [ ! -f "${CATALOG_PATH}" ]; then
    echo "Missing model catalog at ${CATALOG_PATH}" >&2
    exit 1
fi

if [ ! -f "${CHANNEL_PATH}" ]; then
    echo "Missing stable channel at ${CHANNEL_PATH}" >&2
    exit 1
fi

if [ ! -f "${RUNTIME_MANIFEST}" ]; then
    echo "Missing runtime manifest at ${RUNTIME_MANIFEST}" >&2
    exit 1
fi

if [ -z "${CATALOG_VERSION}" ]; then
    CATALOG_VERSION="$(json_value "${CATALOG_PATH}" "catalogVersion")"
fi

if [ -z "${RUNTIME_VERSION}" ]; then
    RUNTIME_VERSION="$(json_value "${RUNTIME_MANIFEST}" "runtimeVersion")"
fi

CATALOG_TAG="catalog-${CATALOG_VERSION}"
RUNTIME_TAG="runtime-${RUNTIME_VERSION}"
CATALOG_ASSET="${OUTPUT_DIR}/model-catalog.json"
CHANNEL_ASSET="${OUTPUT_DIR}/stable-channel.json"
RUNTIME_ARCHIVE="${OUTPUT_DIR}/runtime-macos-arm64-${RUNTIME_VERSION}.zip"

mkdir -p "${OUTPUT_DIR}"
cp "${CATALOG_PATH}" "${CATALOG_ASSET}"

CATALOG_SHA="$(sha256_file "${CATALOG_ASSET}")"
CATALOG_SIZE="$(file_size "${CATALOG_ASSET}")"
RUNTIME_SHA=""
RUNTIME_SIZE=""

if [ "${SKIP_RUNTIME_ARCHIVE}" = "1" ]; then
    RUNTIME_SHA="$(json_value "${CHANNEL_PATH}" "runtimes.0.sha256")"
    RUNTIME_SIZE="$(json_value "${CHANNEL_PATH}" "runtimes.0.sizeBytes")"
else
    echo "Creating ${RUNTIME_ARCHIVE}"
    rm -f "${RUNTIME_ARCHIVE}"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "${RUNTIME_DIR}" "${RUNTIME_ARCHIVE}"
    RUNTIME_SHA="$(sha256_file "${RUNTIME_ARCHIVE}")"
    RUNTIME_SIZE="$(file_size "${RUNTIME_ARCHIVE}")"
fi

CATALOG_URL="https://github.com/${REPOSITORY}/releases/download/${CATALOG_TAG}/model-catalog.json"
RUNTIME_URL="https://github.com/${REPOSITORY}/releases/download/${RUNTIME_TAG}/runtime-macos-arm64-${RUNTIME_VERSION}.zip"

/usr/bin/python3 - "${CHANNEL_ASSET}" \
    "${CHANNEL}" \
    "${CATALOG_VERSION}" \
    "${CATALOG_URL}" \
    "${CATALOG_SHA}" \
    "${CATALOG_SIZE}" \
    "${RUNTIME_VERSION}" \
    "${RUNTIME_URL}" \
    "${RUNTIME_SHA}" \
    "${RUNTIME_SIZE}" <<'PY'
import json
import sys

output_path = sys.argv[1]
channel = sys.argv[2]
catalog_version = sys.argv[3]
catalog_url = sys.argv[4]
catalog_sha = sys.argv[5]
catalog_size = int(sys.argv[6])
runtime_version = sys.argv[7]
runtime_url = sys.argv[8]
runtime_sha = sys.argv[9]
runtime_size = int(sys.argv[10]) if sys.argv[10] else None

manifest = {
    "schemaVersion": 1,
    "channel": channel,
    "catalog": {
        "version": catalog_version,
        "url": catalog_url,
        "sha256": catalog_sha,
        "sizeBytes": catalog_size,
    },
    "runtimes": [
        {
            "version": runtime_version,
            "platform": "macos",
            "arch": "arm64",
            "url": runtime_url,
            "sha256": runtime_sha,
            "sizeBytes": runtime_size,
            "compatibilityApi": 1,
        }
    ],
}

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

VALIDATOR_ARGS=(
    "${SCRIPT_DIR}/validate-release-metadata.py"
    --catalog "${CATALOG_ASSET}"
    --channel "${CHANNEL_ASSET}"
    --runtime-manifest "${RUNTIME_MANIFEST}"
)

if [ "${SKIP_RUNTIME_ARCHIVE}" = "1" ]; then
    VALIDATOR_ARGS+=(--allow-runtime-placeholders)
fi

/usr/bin/python3 "${VALIDATOR_ARGS[@]}"

if [ "${WRITE_CHANNEL}" = "1" ]; then
    cp "${CHANNEL_ASSET}" "${CHANNEL_PATH}"
    echo "Updated ${CHANNEL_PATH}"
fi

echo ""
echo "Release assets prepared in ${OUTPUT_DIR}"
echo "Catalog asset: ${CATALOG_ASSET}"
echo "Catalog SHA-256: ${CATALOG_SHA}"
if [ "${SKIP_RUNTIME_ARCHIVE}" = "0" ]; then
    echo "Runtime asset: ${RUNTIME_ARCHIVE}"
    echo "Runtime SHA-256: ${RUNTIME_SHA}"
else
    echo "Runtime archive skipped; existing runtime SHA/size were reused in the generated channel."
fi
echo "Channel candidate: ${CHANNEL_ASSET}"
