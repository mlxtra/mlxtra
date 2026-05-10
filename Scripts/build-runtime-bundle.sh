#!/bin/bash
set -e

# MLX-VLM Runtime Bundle Builder for macOS
# Creates a self-contained Python environment with mlx-vlm and dependencies

VERSION="0.1.0"
PYTHON_VERSION="3.12.8"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macos11.pkg"
MLX_VERSION="0.31.1"
MLX_VLM_VERSION="0.4.4"
MLX_AUDIO_VERSION="0.4.2"
MFLUX_VERSION="0.17.5"
TRANSFORMERS_VERSION="5.5.4"
HUGGINGFACE_HUB_VERSION="1.10.2"
PILLOW_VERSION="12.2.0"
NUMPY_VERSION="2.4.4"
TORCH_VERSION="2.11.0"
TORCHVISION_VERSION="0.26.0"
ACE_STEP_REF="97ac5116c103c05532e4968a83b9046181248da6"
ACE_STEP_PACKAGE="git+https://github.com/ace-step/ACE-Step-1.5.git@${ACE_STEP_REF}"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${SCRIPT_DIR}/../.build/runtime"
OUTPUT_DIR="${PROJECT_DIR}/MLXHub/Resources/runtime/macos-arm64"

echo "=== MLX-VLM Runtime Bundle Builder v${VERSION} ==="
echo ""

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "Step 1: Downloading Python ${PYTHON_VERSION}..."
if [ ! -f "${BUILD_DIR}/python-${PYTHON_VERSION}-macos11.pkg" ]; then
    curl -L -o "${BUILD_DIR}/python-${PYTHON_VERSION}-macos11.pkg" "${PYTHON_URL}"
fi

echo "Step 2: Extracting Python..."
mkdir -p "${BUILD_DIR}/python"
pkgutil --expand "${BUILD_DIR}/python-${PYTHON_VERSION}-macos11.pkg" "${BUILD_DIR}/python_pkg"
# Extract Python framework
mkdir -p "${BUILD_DIR}/python/Frameworks"
cd "${BUILD_DIR}/python_pkg"
for pkg in *.pkg; do
    if [[ "$pkg" == "Python"*".pkg" ]]; then
        tar -xvf "${pkg}/Payload" -C "${BUILD_DIR}/python/Frameworks" 2>/dev/null || true
    fi
done
cd -

echo "Step 3: Setting up Python virtual environment..."
PYTHON_BIN="$(find "${BUILD_DIR}/python/Frameworks" -path "*/Versions/3.12/bin/python3" -type f | head -n 1)"
if [ ! -f "${PYTHON_BIN}" ]; then
    echo "Bundled Python ${PYTHON_VERSION} was not extracted correctly; refusing to build a non-portable runtime from a developer-local Python."
    exit 1
fi
"${PYTHON_BIN}" -m venv --copies "${BUILD_DIR}/venv"

echo "Step 4: Installing dependencies..."
VENV_PIP="${BUILD_DIR}/venv/bin/pip"
VENV_PYTHON="${BUILD_DIR}/venv/bin/python"

# Upgrade pip
"${VENV_PIP}" install --upgrade pip

# Install core dependencies
echo "Installing mlx..."
"${VENV_PIP}" install "mlx==${MLX_VERSION}"

echo "Installing mlx-vlm..."
"${VENV_PIP}" install "mlx-vlm==${MLX_VLM_VERSION}"

echo "Installing mlx-audio..."
"${VENV_PIP}" install "mlx-audio==${MLX_AUDIO_VERSION}"

echo "Installing mflux..."
"${VENV_PIP}" install "mflux==${MFLUX_VERSION}"

echo "Installing transformers..."
"${VENV_PIP}" install "transformers==${TRANSFORMERS_VERSION}"

echo "Installing huggingface-hub..."
"${VENV_PIP}" install "huggingface-hub==${HUGGINGFACE_HUB_VERSION}"

echo "Installing pillow..."
"${VENV_PIP}" install "pillow==${PILLOW_VERSION}"

echo "Installing numpy..."
"${VENV_PIP}" install "numpy==${NUMPY_VERSION}"

echo "Installing torch..."
"${VENV_PIP}" install "torch==${TORCH_VERSION}" --index-url https://download.pytorch.org/whl/cpu

echo "Installing torchvision..."
"${VENV_PIP}" install "torchvision==${TORCHVISION_VERSION}" --index-url https://download.pytorch.org/whl/cpu

echo "Step 5: Creating runtime structure..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/venv" "${OUTPUT_DIR}/python" "${OUTPUT_DIR}/acestep-venv"

# Copy Python framework first so venv interpreter links can be made relative to it.
mkdir -p "${OUTPUT_DIR}/python"
if [ -d "${BUILD_DIR}/python/Frameworks" ]; then
    cp -R "${BUILD_DIR}/python/Frameworks" "${OUTPUT_DIR}/python/"
fi

# Copy venv
cp -R "${BUILD_DIR}/venv" "${OUTPUT_DIR}/venv"

echo "Creating isolated ACE-Step runtime..."
"${VENV_PYTHON}" -m venv --copies "${BUILD_DIR}/acestep-venv"
ACE_PIP="${BUILD_DIR}/acestep-venv/bin/pip"
"${ACE_PIP}" install --upgrade pip
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

        first_line="$(head -n 1 "${script}")"
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

echo "Step 6: Creating runtime manifest..."
cat > "${OUTPUT_DIR}/runtime-manifest.json" << EOF
{
  "runtimeVersion": "${VERSION}",
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
    "mlx==${MLX_VERSION}",
    "mlx-vlm==${MLX_VLM_VERSION}",
    "mlx-audio==${MLX_AUDIO_VERSION}",
    "mflux==${MFLUX_VERSION}",
    "transformers==${TRANSFORMERS_VERSION}",
    "huggingface-hub==${HUGGINGFACE_HUB_VERSION}",
    "pillow==${PILLOW_VERSION}",
    "numpy==${NUMPY_VERSION}",
    "torch==${TORCH_VERSION}",
    "torchvision==${TORCHVISION_VERSION}"
  ],
  "isolatedPackages": [
    "ace-step @ ${ACE_STEP_PACKAGE}"
  ],
  "supportedBackends": [
    "vlm",
    "llm",
    "image",
    "audio",
    "music"
  ],
  "capabilities": [
    "chat",
    "vision",
    "image-generation",
    "image-editing",
    "speech-generation",
    "music-generation"
  ],
  "supportedModels": [
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "google/gemma-4-e4b-it",
    "mlx-community/Qwen3.5-2B-MLX-4bit",
    "black-forest-labs/FLUX.2-klein-4B",
    "kugelaudio/kugelaudio-0-open",
    "ACE-Step/acestep-v15-turbo-continuous"
  ]
}
EOF

echo "Step 7: Verifying installation..."
RUNTIME_PYTHONHOME="${OUTPUT_DIR}/python/Frameworks/Versions/3.12"

PYTHONHOME="${RUNTIME_PYTHONHOME}" PYTHONDONTWRITEBYTECODE=1 "${OUTPUT_DIR}/venv/bin/python" -c "
import sys
import importlib.metadata as metadata
print(f'Python: {sys.version}')

expected = {
    'mlx': '${MLX_VERSION}',
    'mlx-vlm': '${MLX_VLM_VERSION}',
    'mlx-audio': '${MLX_AUDIO_VERSION}',
    'mflux': '${MFLUX_VERSION}',
    'transformers': '${TRANSFORMERS_VERSION}',
    'huggingface-hub': '${HUGGINGFACE_HUB_VERSION}',
    'pillow': '${PILLOW_VERSION}',
    'numpy': '${NUMPY_VERSION}',
    'torch': '${TORCH_VERSION}',
    'torchvision': '${TORCHVISION_VERSION}',
}
for package, version in expected.items():
    installed = metadata.version(package)
    if installed != version:
        raise RuntimeError(f'{package} version mismatch: expected {version}, got {installed}')
    print(f'{package}: {installed}')

print('All dependencies verified!')
"

PYTHONHOME="${RUNTIME_PYTHONHOME}" PYTHONDONTWRITEBYTECODE=1 "${OUTPUT_DIR}/acestep-venv/bin/python" -c "
import importlib.metadata as metadata
from acestep.inference import GenerationConfig, GenerationParams, generate_music
print('ACE-Step: OK')
print('ace-step: ' + metadata.version('ace-step'))
"

echo ""
echo "=== Build Complete ==="
echo "Runtime bundle created at: ${OUTPUT_DIR}"
echo "Size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo ""
echo "To use:"
echo "  1. The bundle is embedded in the app at MLXHub/Resources/runtime/macos-arm64"
echo "  2. Python executable: ${OUTPUT_DIR}/venv/bin/python3"
echo "  3. Test: PYTHONHOME=${OUTPUT_DIR}/python/Frameworks/Versions/3.12 ${OUTPUT_DIR}/venv/bin/python3 -c 'import csv; print(\"OK\")'"
