#!/bin/bash
set -euo pipefail

# MLX-VLM Runtime Bundle Builder for macOS
# Creates a self-contained Python environment with mlx-vlm and dependencies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/runtime-dependencies.sh"

BUILD_DIR="${PROJECT_DIR}/.build/runtime"
CACHE_DIR="${PROJECT_DIR}/.build/runtime-cache"
OUTPUT_DIR="${PROJECT_DIR}/MLXtra/Resources/runtime/macos-arm64"
FORCED_WHEELHOUSE="${BUILD_DIR}/forced-wheelhouse"
FRESH_CACHE=0
SKIP_VERIFY=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --build-dir PATH     Temporary build directory. Default: ${BUILD_DIR}
  --cache-dir PATH     Persistent download/pip cache. Default: ${CACHE_DIR}
  --output-dir PATH    Runtime output directory. Default: ${OUTPUT_DIR}
  --fresh-cache        Delete the persistent runtime cache before building.
  --skip-verify        Skip final import/version verification.
  -h, --help           Show this help.
USAGE
}

require_option_value() {
    local option="$1"
    local value="${2:-}"

    if [ -z "${value}" ] || [[ "${value}" == --* ]]; then
        echo "${option} requires a path value." >&2
        usage >&2
        exit 1
    fi
}

verify_sha256() {
    local path="$1"
    local expected="$2"
    local actual

    actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "Checksum mismatch for ${path}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    fi
}

remove_external_symlinks() {
    local scan_dir="$1"
    local root_dir="$2"

    /usr/bin/python3 - "${scan_dir}" "${root_dir}" <<'PY'
import pathlib
import sys

scan = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
removed = []

for path in scan.rglob("*"):
    if not path.is_symlink():
        continue
    resolved = path.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        path.unlink()
        removed.append(str(path.relative_to(root)))

if removed:
    print("Removed runtime symlinks that pointed outside the bundle:")
    for entry in removed:
        print(f"  {entry}")
PY
}

validate_self_contained_symlinks() {
    local root_dir="$1"

    /usr/bin/python3 - "${root_dir}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
bad = []

for path in root.rglob("*"):
    if not path.is_symlink():
        continue
    resolved = path.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        bad.append((str(path.relative_to(root)), str(resolved)))

if bad:
    print("Runtime contains symlinks that point outside the bundle:", file=sys.stderr)
    for path, resolved in bad[:50]:
        print(f"  {path} -> {resolved}", file=sys.stderr)
    if len(bad) > 50:
        print(f"  ... and {len(bad) - 50} more", file=sys.stderr)
    raise SystemExit(1)
PY
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-dir)
            require_option_value "$1" "${2:-}"
            BUILD_DIR="$2"
            shift 2
            ;;
        --cache-dir)
            require_option_value "$1" "${2:-}"
            CACHE_DIR="$2"
            shift 2
            ;;
        --output-dir)
            require_option_value "$1" "${2:-}"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --fresh-cache)
            FRESH_CACHE=1
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

absolute_path() {
    local path="$1"
    if [[ "${path}" == /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s/%s\n' "$(pwd -P)" "${path}"
    fi
}

BUILD_DIR="$(absolute_path "${BUILD_DIR}")"
CACHE_DIR="$(absolute_path "${CACHE_DIR}")"
OUTPUT_DIR="$(absolute_path "${OUTPUT_DIR}")"
FORCED_WHEELHOUSE="${BUILD_DIR}/forced-wheelhouse"

validate_runtime_dependency_lock

echo "=== MLX-VLM Runtime Bundle Builder v${RUNTIME_VERSION} ==="
echo ""

if [ "${FRESH_CACHE}" = "1" ]; then
    echo "Clearing runtime cache at ${CACHE_DIR}"
    rm -rf "${CACHE_DIR}"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${CACHE_DIR}"
mkdir -p "${OUTPUT_DIR}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-${CACHE_DIR}/pip}"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "${PIP_CACHE_DIR}"

echo "Step 1: Preparing Python ${PYTHON_VERSION} package..."
PYTHON_PKG_PATH="${CACHE_DIR}/${PYTHON_PKG_NAME}"
if [ ! -f "${PYTHON_PKG_PATH}" ]; then
    curl -fL --retry 3 --continue-at - -o "${PYTHON_PKG_PATH}" "${PYTHON_URL}"
else
    echo "Using cached Python package: ${PYTHON_PKG_PATH}"
fi
if ! verify_sha256 "${PYTHON_PKG_PATH}" "${PYTHON_PKG_SHA256}"; then
    echo "Deleting invalid cached Python package. Re-run the script to download a clean copy." >&2
    rm -f "${PYTHON_PKG_PATH}"
    exit 1
fi

echo "Step 2: Extracting Python..."
mkdir -p "${BUILD_DIR}/python"
pkgutil --expand "${PYTHON_PKG_PATH}" "${BUILD_DIR}/python_pkg"
mkdir -p "${BUILD_DIR}/python/Frameworks"
(
    cd "${BUILD_DIR}/python_pkg"
    for pkg in *.pkg; do
        if [[ "$pkg" == "Python"*".pkg" ]]; then
            if ! ditto -x -z "${pkg}/Payload" "${BUILD_DIR}/python/Frameworks" 2>/dev/null; then
                tar -xf "${pkg}/Payload" -C "${BUILD_DIR}/python/Frameworks" 2>/dev/null || true
            fi
        fi
    done
)

echo "Step 3: Setting up Python virtual environment..."
PYTHON_BIN="$(find "${BUILD_DIR}/python/Frameworks" -path "*/Versions/3.12/bin/python3.12" -type f | head -n 1)"
if [ ! -f "${PYTHON_BIN}" ]; then
    PYTHON_BIN="$(find "${BUILD_DIR}/python/Frameworks" -path "*/Versions/3.12/bin/python3" -type f | head -n 1)"
fi
if [ ! -f "${PYTHON_BIN}" ]; then
    echo "Bundled Python ${PYTHON_VERSION} was not extracted correctly; refusing to build a non-portable runtime from a developer-local Python."
    exit 1
fi
echo "Preparing bundled Python for local execution..."
install_name_tool -change "/Library/Frameworks/Python.framework/Versions/3.12/Python" "@executable_path/../Python" "${PYTHON_BIN}" 2>/dev/null || true
PYTHON_APP_BIN="${BUILD_DIR}/python/Frameworks/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
if [ -f "${PYTHON_APP_BIN}" ]; then
    install_name_tool -change "/Library/Frameworks/Python.framework/Versions/3.12/Python" "@executable_path/../../../../Python" "${PYTHON_APP_BIN}" 2>/dev/null || true
    codesign --force --sign - "${PYTHON_APP_BIN}" >/dev/null 2>&1 || true
fi
codesign --force --sign - "${PYTHON_BIN}" >/dev/null 2>&1 || true

relocate_build_python_framework_dependencies() {
    local framework_dir="${BUILD_DIR}/python/Frameworks/Versions/3.12"
    local framework_lib_dir="${framework_dir}/lib"
    local dynload_dir="${framework_lib_dir}/python3.12/lib-dynload"
    local original_lib_dir="/Library/Frameworks/Python.framework/Versions/3.12/lib"

    for dylib in "${framework_lib_dir}"/*.dylib; do
        if [ ! -f "${dylib}" ] || [ -L "${dylib}" ]; then
            continue
        fi

        dep_name="$(basename "${dylib}")"
        install_name_tool -id "@rpath/${dep_name}" "${dylib}" 2>/dev/null || true

        for dep_path in "${framework_lib_dir}"/*.dylib; do
            if [ ! -f "${dep_path}" ] || [ -L "${dep_path}" ]; then
                continue
            fi
            dep_name="$(basename "${dep_path}")"
            install_name_tool -change "${original_lib_dir}/${dep_name}" "@loader_path/${dep_name}" "${dylib}" 2>/dev/null || true
        done
    done

    if [ -d "${dynload_dir}" ]; then
        for extension in "${dynload_dir}"/*.so; do
            if [ ! -f "${extension}" ]; then
                continue
            fi

            for dep_path in "${framework_lib_dir}"/*.dylib; do
                if [ ! -f "${dep_path}" ] || [ -L "${dep_path}" ]; then
                    continue
                fi
                dep_name="$(basename "${dep_path}")"
                install_name_tool -change "${original_lib_dir}/${dep_name}" "@loader_path/../../${dep_name}" "${extension}" 2>/dev/null || true
            done
        done

        codesign --force --sign - "${dynload_dir}"/*.so >/dev/null 2>&1 || true
    fi

    codesign --force --sign - "${framework_lib_dir}"/*.dylib >/dev/null 2>&1 || true
}

relocate_build_python_framework_dependencies

create_build_venv() {
    local venv_dir="$1"
    local bundled_lib="@executable_path/../../python/Frameworks/Versions/3.12/Python"

    "${PYTHON_BIN}" -m venv --copies --without-pip "${venv_dir}"
    if [ ! -f "${venv_dir}/bin/python3.12" ]; then
        echo "Virtual environment at ${venv_dir} did not create a python3.12 executable."
        exit 1
    fi

    for venv_python in "${venv_dir}/bin/python" "${venv_dir}/bin/python3" "${venv_dir}/bin/python3.12"; do
        if [ ! -f "${venv_python}" ]; then
            continue
        fi
        install_name_tool -change "/Library/Frameworks/Python.framework/Versions/3.12/Python" "${bundled_lib}" "${venv_python}" 2>/dev/null || true
        install_name_tool -change "@executable_path/../Python" "${bundled_lib}" "${venv_python}" 2>/dev/null || true
        codesign --force --sign - "${venv_python}" >/dev/null 2>&1 || true
    done

    "${venv_dir}/bin/python3.12" -m ensurepip --upgrade --default-pip
}

create_build_venv "${BUILD_DIR}/venv"

echo "Step 4: Installing dependencies..."
VENV_PIP="${BUILD_DIR}/venv/bin/pip"
VENV_PYTHON="${BUILD_DIR}/venv/bin/python"

"${VENV_PIP}" install --upgrade pip

mkdir -p "${FORCED_WHEELHOUSE}"
echo "Downloading MLX wheels for ${RUNTIME_MLX_WHEEL_PLATFORM}..."
"${VENV_PIP}" download \
    --only-binary=:all: \
    --platform "${RUNTIME_MLX_WHEEL_PLATFORM}" \
    --implementation cp \
    --python-version 312 \
    --abi cp312 \
    --dest "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"

echo "Installing MLX wheels for ${RUNTIME_MLX_WHEEL_PLATFORM}..."
"${VENV_PIP}" install \
    --no-index \
    --find-links "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"

for package in "${RUNTIME_MAIN_PYPI_PACKAGES[@]}"; do
    echo "Installing ${package}..."
    "${VENV_PIP}" install "${package}"
done

for package in "${RUNTIME_TORCH_PACKAGES[@]}"; do
    echo "Installing ${package}..."
    "${VENV_PIP}" install "${package}" --index-url https://download.pytorch.org/whl/cpu
done

echo "Step 5: Creating runtime structure..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/venv" "${OUTPUT_DIR}/python" "${OUTPUT_DIR}/acestep-venv"

# Copy Python framework first so venv interpreter links can be made relative to it.
mkdir -p "${OUTPUT_DIR}/python"
if [ -d "${BUILD_DIR}/python/Frameworks" ]; then
    cp -R "${BUILD_DIR}/python/Frameworks" "${OUTPUT_DIR}/python/"
fi
remove_external_symlinks "${OUTPUT_DIR}/python/Frameworks" "${OUTPUT_DIR}"

cp -R "${BUILD_DIR}/venv" "${OUTPUT_DIR}/venv"

ACE_DOWNLOAD_HELPER_SOURCE="${PROJECT_DIR}/MLXtra/Resources/runtime/macos-arm64/acestep_download_helper.py"
ACE_DOWNLOAD_HELPER_DEST="${OUTPUT_DIR}/acestep_download_helper.py"
if [ ! -f "${ACE_DOWNLOAD_HELPER_SOURCE}" ] && [ ! -f "${ACE_DOWNLOAD_HELPER_DEST}" ]; then
    echo "ACE-Step download helper source is missing." >&2
    exit 1
fi
if [ -f "${ACE_DOWNLOAD_HELPER_SOURCE}" ]; then
    source_real="$(cd "$(dirname "${ACE_DOWNLOAD_HELPER_SOURCE}")" && pwd -P)/$(basename "${ACE_DOWNLOAD_HELPER_SOURCE}")"
    dest_real="$(cd "${OUTPUT_DIR}" && pwd -P)/acestep_download_helper.py"
    if [ "${source_real}" != "${dest_real}" ]; then
        cp -f "${ACE_DOWNLOAD_HELPER_SOURCE}" "${ACE_DOWNLOAD_HELPER_DEST}"
    fi
fi

echo "Creating isolated ACE-Step runtime..."
create_build_venv "${BUILD_DIR}/acestep-venv"
ACE_PIP="${BUILD_DIR}/acestep-venv/bin/pip"
"${ACE_PIP}" install --upgrade pip
echo "Installing ACE-Step MLX wheels for ${RUNTIME_MLX_WHEEL_PLATFORM}..."
"${ACE_PIP}" install \
    --no-index \
    --find-links "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"
"${ACE_PIP}" install "${ACE_STEP_PACKAGE}"
cp -R "${BUILD_DIR}/acestep-venv" "${OUTPUT_DIR}/acestep-venv"

relocate_venv() {
    local venv_dir="$1"
    local framework_python="${OUTPUT_DIR}/python/Frameworks/Versions/3.12/bin/python3.12"
    local venv_python="${venv_dir}/bin/python3.12"
    local original_lib="/Library/Frameworks/Python.framework/Versions/3.12/Python"
    local bundled_lib="@executable_path/../../python/Frameworks/Versions/3.12/Python"

    cat > "${venv_dir}/pyvenv.cfg" << CFG
home = ../python/Frameworks/Versions/3.12/bin
include-system-site-packages = false
version = ${PYTHON_VERSION}
executable = ../python/Frameworks/Versions/3.12/bin/python3.12
command = bundled-python -m venv --copies ${venv_dir}
CFG

    cp -f "${framework_python}" "${venv_python}"
    install_name_tool -change "${original_lib}" "${bundled_lib}" "${venv_python}"
    install_name_tool -change "@executable_path/../Python" "${bundled_lib}" "${venv_python}"
    codesign --force --sign - "${venv_python}"
    ln -sfn "python3.12" "${venv_dir}/bin/python3"
    ln -sfn "python3.12" "${venv_dir}/bin/python"
    rm -f "${venv_dir}/bin/activate" "${venv_dir}/bin/activate.csh" "${venv_dir}/bin/activate.fish"

    for script in "${venv_dir}/bin/"*; do
        if [ ! -f "${script}" ] || [ "${script}" = "${venv_python}" ]; then
            continue
        fi

        IFS= read -r first_line < "${script}" || first_line=""
        if [[ "${first_line}" != '#!'*python* ]]; then
            continue
        fi

        temp_script="${script}.relocated"
        {
            printf '%s\n' '#!/bin/sh'
            printf '%s\n' "'''exec' \"\$(dirname \"\$0\")/python\" \"\$0\" \"\$@\""
            printf '%s\n' "' '''"
            tail -n +2 "${script}"
        } > "${temp_script}"
        chmod --reference="${script}" "${temp_script}" 2>/dev/null || chmod +x "${temp_script}"
        mv "${temp_script}" "${script}"
    done
}

codesign_native_artifacts() {
    local target_dir="$1"

    while IFS= read -r -d '' binary; do
        codesign --force --sign - "${binary}" 2>/dev/null || true
    done < <(find "${target_dir}" -type f \( -name "*.so" -o -name "*.dylib" \) -print0)
}

relocate_python_framework() {
    local framework_dir="${OUTPUT_DIR}/python/Frameworks/Versions/3.12"
    local framework_lib_dir="${framework_dir}/lib"
    local dynload_dir="${framework_lib_dir}/python3.12/lib-dynload"
    local python_bin="${framework_dir}/bin/python3.12"
    local python_bin_intel="${framework_dir}/bin/python3.12-intel64"
    local python_lib="${framework_dir}/Python"
    local python_app="${framework_dir}/Resources/Python.app/Contents/MacOS/Python"
    local original_lib="/Library/Frameworks/Python.framework/Versions/3.12/Python"
    local original_lib_dir="/Library/Frameworks/Python.framework/Versions/3.12/lib"

    if [ ! -f "${python_bin}" ] || [ ! -f "${python_lib}" ] || [ ! -f "${python_app}" ]; then
        echo "Bundled Python framework is incomplete; cannot relocate runtime."
        exit 1
    fi

    install_name_tool -change "${original_lib}" "@executable_path/../Python" "${python_bin}"
    if [ -f "${python_bin_intel}" ]; then
        install_name_tool -change "${original_lib}" "@executable_path/../Python" "${python_bin_intel}"
    fi
    install_name_tool -id "@rpath/Python" -change "${original_lib}" "@rpath/Python" "${python_lib}"
    install_name_tool -change "${original_lib}" "@executable_path/../../../../Python" "${python_app}"

    for dylib in "${framework_lib_dir}"/*.dylib; do
        if [ ! -f "${dylib}" ] || [ -L "${dylib}" ]; then
            continue
        fi

        dep_name="$(basename "${dylib}")"
        install_name_tool -id "@rpath/${dep_name}" "${dylib}" 2>/dev/null || true

        for dep_path in "${framework_lib_dir}"/*.dylib; do
            if [ ! -f "${dep_path}" ] || [ -L "${dep_path}" ]; then
                continue
            fi
            dep_name="$(basename "${dep_path}")"
            install_name_tool -change "${original_lib_dir}/${dep_name}" "@loader_path/${dep_name}" "${dylib}" 2>/dev/null || true
        done
    done

    if [ -d "${dynload_dir}" ]; then
        for extension in "${dynload_dir}"/*.so; do
            if [ ! -f "${extension}" ]; then
                continue
            fi

            for dep_path in "${framework_lib_dir}"/*.dylib; do
                if [ ! -f "${dep_path}" ] || [ -L "${dep_path}" ]; then
                    continue
                fi
                dep_name="$(basename "${dep_path}")"
                install_name_tool -change "${original_lib_dir}/${dep_name}" "@loader_path/../../${dep_name}" "${extension}" 2>/dev/null || true
            done
        done
    fi

    codesign --force --sign - "${python_bin}" "${python_lib}" "${python_app}"
    if [ -f "${python_bin_intel}" ]; then
        codesign --force --sign - "${python_bin_intel}"
    fi
    codesign --force --sign - "${framework_lib_dir}"/*.dylib
    if [ -d "${dynload_dir}" ]; then
        codesign --force --sign - "${dynload_dir}"/*.so
    fi
}

relocate_python_framework
relocate_venv "${OUTPUT_DIR}/venv"
relocate_venv "${OUTPUT_DIR}/acestep-venv"
codesign_native_artifacts "${OUTPUT_DIR}/venv"
codesign_native_artifacts "${OUTPUT_DIR}/acestep-venv"

validate_mlx_wheel_platform() {
    local site_packages="$1"

    RUNTIME_MLX_WHEEL_PLATFORM="${RUNTIME_MLX_WHEEL_PLATFORM}" /usr/bin/python3 - "${site_packages}" <<'PY'
import os
import pathlib
import sys

site_packages = pathlib.Path(sys.argv[1])
expected_platform = os.environ["RUNTIME_MLX_WHEEL_PLATFORM"]

for wheel_stem in ("mlx", "mlx_metal"):
    wheel_files = sorted(site_packages.glob(f"{wheel_stem}-*.dist-info/WHEEL"))
    if not wheel_files:
        raise SystemExit(f"{wheel_stem} WHEEL metadata not found in {site_packages}")

    tags = []
    for line in wheel_files[-1].read_text().splitlines():
        if line.startswith("Tag: "):
            tags.append(line.removeprefix("Tag: ").strip())

    if not any(expected_platform in tag for tag in tags):
        raise SystemExit(
            f"{wheel_stem} is not using {expected_platform}; found tags: {tags}"
        )
PY
}

validate_mlx_wheel_platform "${OUTPUT_DIR}/venv/lib/python3.12/site-packages"
validate_mlx_wheel_platform "${OUTPUT_DIR}/acestep-venv/lib/python3.12/site-packages"
if [ ! -f "${OUTPUT_DIR}/acestep_download_helper.py" ]; then
    echo "ACE-Step download helper is missing from the runtime bundle." >&2
    exit 1
fi
validate_self_contained_symlinks "${OUTPUT_DIR}"

json_array_items() {
    local indent="$1"
    shift
    local index=0
    local total="$#"

    for item in "$@"; do
        index=$((index + 1))
        printf '%*s"%s"' "${indent}" "" "${item}"
        if [ "${index}" -lt "${total}" ]; then
            printf ','
        fi
        printf '\n'
    done
}

json_number_array_items() {
    local indent="$1"
    shift
    local index=0
    local total="$#"

    for item in "$@"; do
        index=$((index + 1))
        printf '%*s%s' "${indent}" "" "${item}"
        if [ "${index}" -lt "${total}" ]; then
            printf ','
        fi
        printf '\n'
    done
}

echo "Step 6: Creating runtime manifest..."
cat > "${OUTPUT_DIR}/runtime-manifest.json" << EOF
{
  "runtimeVersion": "${RUNTIME_VERSION}",
  "compatibilityApi": 1,
  "platform": "macos",
  "arch": "arm64",
  "channel": "stable",
  "pythonVersion": "${PYTHON_VERSION}",
  "pythonPath": "venv/bin/python3",
  "executables": {
    "python": "venv/bin/python3",
    "pip": "venv/bin/pip"
  },
  "packages": [
$(json_array_items 4 "${RUNTIME_MAIN_PACKAGES[@]}")
  ],
  "isolatedPackages": [
    "ace-step @ ${ACE_STEP_PACKAGE}"
  ],
  "supportedBackends": [
$(json_array_items 4 "${RUNTIME_SUPPORTED_BACKENDS[@]}")
  ],
  "capabilities": [
$(json_array_items 4 "${RUNTIME_CAPABILITIES[@]}")
  ],
  "imageRuntimes": {
    "mflux": {
      "configs": [
$(json_array_items 8 "${RUNTIME_MFLUX_CONFIGS[@]}")
      ],
      "classes": [
$(json_array_items 8 "${RUNTIME_MFLUX_CLASSES[@]}")
      ],
      "quantizeBits": [
$(json_number_array_items 8 "${RUNTIME_MFLUX_QUANTIZE_BITS[@]}")
      ]
    }
  },
  "audioRuntimes": {
    "adapters": [
$(json_array_items 6 "${RUNTIME_AUDIO_ADAPTERS[@]}")
    ]
  }
}
EOF

echo "Step 7: Verifying installation..."
RUNTIME_PYTHONHOME="${OUTPUT_DIR}/python/Frameworks/Versions/3.12"

if [ "${SKIP_VERIFY}" = "1" ]; then
    echo "Skipping runtime import/version verification because --skip-verify was set"
else
RUNTIME_EXPECTED_PACKAGES="$(printf '%s\n' "${RUNTIME_MAIN_PACKAGES[@]}")" \
RUNTIME_MLX_METAL_VERSION="${MLX_METAL_VERSION}" \
PYTHONHOME="${RUNTIME_PYTHONHOME}" PYTHONDONTWRITEBYTECODE=1 "${OUTPUT_DIR}/venv/bin/python" -c "
import os
import sys
import importlib.metadata as metadata
print(f'Python: {sys.version}')

expected = {}
for pinned in os.environ['RUNTIME_EXPECTED_PACKAGES'].splitlines():
    package, version = pinned.split('==', 1)
    package = package.split('[', 1)[0]
    expected[package] = version

for package, version in expected.items():
    installed = metadata.version(package)
    if installed != version:
        raise RuntimeError(f'{package} version mismatch: expected {version}, got {installed}')
    print(f'{package}: {installed}')

mlx_metal = metadata.version('mlx-metal')
if mlx_metal != os.environ['RUNTIME_MLX_METAL_VERSION']:
    raise RuntimeError(f'mlx-metal version mismatch: expected {os.environ[\"RUNTIME_MLX_METAL_VERSION\"]}, got {mlx_metal}')
print(f'mlx-metal: {mlx_metal}')

print('All dependencies verified!')
"

RUNTIME_MLX_METAL_VERSION="${MLX_METAL_VERSION}" \
PYTHONHOME="${RUNTIME_PYTHONHOME}" PYTHONDONTWRITEBYTECODE=1 "${OUTPUT_DIR}/acestep-venv/bin/python" -c "
import os
import importlib.metadata as metadata
from acestep.inference import GenerationConfig, GenerationParams, generate_music
print('ACE-Step: OK')
print('ace-step: ' + metadata.version('ace-step'))
mlx_metal = metadata.version('mlx-metal')
if mlx_metal != os.environ['RUNTIME_MLX_METAL_VERSION']:
    raise RuntimeError(f'mlx-metal version mismatch: expected {os.environ[\"RUNTIME_MLX_METAL_VERSION\"]}, got {mlx_metal}')
print('ACE-Step mlx-metal: ' + mlx_metal)
"
fi

echo ""
echo "=== Build Complete ==="
echo "Runtime bundle created at: ${OUTPUT_DIR}"
echo "Size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo ""
echo "To use:"
echo "  1. Publish it as a runtime-macos-arm64-<version>.zip GitHub release asset"
echo "  2. Reference that asset from MLXtra/Resources/stable-channel.json"
echo "  3. Python executable: ${OUTPUT_DIR}/venv/bin/python3"
echo "  4. Test: PYTHONHOME=${OUTPUT_DIR}/python/Frameworks/Versions/3.12 ${OUTPUT_DIR}/venv/bin/python3 -c 'import csv; print(\"OK\")'"
