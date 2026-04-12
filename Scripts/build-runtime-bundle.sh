#!/bin/bash
set -e

# MLX-VLM Runtime Bundle Builder for macOS
# Creates a self-contained Python environment with mlx-vlm and dependencies

VERSION="0.1.0"
PYTHON_VERSION="3.12.8"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macos11.pkg"

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
PYTHON_BIN="${BUILD_DIR}/python/Frameworks/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
if [ ! -f "${PYTHON_BIN}" ]; then
    # Fallback: ACE-Step 1.5 requires Python <3.13, so prefer python3.12.
    if command -v python3.12 >/dev/null 2>&1; then
        python3.12 -m venv "${BUILD_DIR}/venv"
    else
        echo "Python 3.12 is required for ACE-Step 1.5 when bundled Python extraction fails."
        exit 1
    fi
else
    "${PYTHON_BIN}" -m venv "${BUILD_DIR}/venv"
fi

echo "Step 4: Installing dependencies..."
VENV_PIP="${BUILD_DIR}/venv/bin/pip"
VENV_PYTHON="${BUILD_DIR}/venv/bin/python"

# Upgrade pip
"${VENV_PIP}" install --upgrade pip

# Install core dependencies
echo "Installing mlx..."
"${VENV_PIP}" install "mlx>=0.21.0"

echo "Installing mlx-vlm..."
"${VENV_PIP}" install "mlx-vlm>=0.4.0"

echo "Installing mlx-audio..."
"${VENV_PIP}" install "mlx-audio>=0.4.2"

echo "Installing mflux..."
"${VENV_PIP}" install "mflux>=0.17.5"

echo "Installing transformers..."
"${VENV_PIP}" install "transformers>=4.40.0"

echo "Installing huggingface-hub..."
"${VENV_PIP}" install "huggingface-hub>=0.20.0"

echo "Installing pillow..."
"${VENV_PIP}" install "pillow>=10.0.0"

echo "Installing numpy..."
"${VENV_PIP}" install "numpy>=1.24.0"

echo "Installing torch..."
"${VENV_PIP}" install "torch>=2.0.0" --index-url https://download.pytorch.org/whl/cpu

echo "Installing torchvision..."
"${VENV_PIP}" install "torchvision>=0.15.0" --index-url https://download.pytorch.org/whl/cpu

echo "Step 5: Creating runtime structure..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/venv" "${OUTPUT_DIR}/python" "${OUTPUT_DIR}/acestep-venv"

# Copy venv
cp -R "${BUILD_DIR}/venv" "${OUTPUT_DIR}/venv"

echo "Creating isolated ACE-Step runtime..."
"${VENV_PYTHON}" -m venv "${BUILD_DIR}/acestep-venv"
ACE_PIP="${BUILD_DIR}/acestep-venv/bin/pip"
"${ACE_PIP}" install --upgrade pip
"${ACE_PIP}" install "git+https://github.com/ace-step/ACE-Step-1.5.git"
cp -R "${BUILD_DIR}/acestep-venv" "${OUTPUT_DIR}/acestep-venv"

# Copy Python framework (minimal)
mkdir -p "${OUTPUT_DIR}/python"
if [ -d "${BUILD_DIR}/python/Frameworks" ]; then
    cp -R "${BUILD_DIR}/python/Frameworks" "${OUTPUT_DIR}/python/"
fi

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
    "mlx>=0.21.0",
    "mlx-vlm>=0.4.0",
    "mlx-audio>=0.4.2",
    "mflux>=0.17.5",
    "transformers>=4.40.0",
    "huggingface-hub>=0.20.0",
    "pillow>=10.0.0",
    "numpy>=1.24.0",
    "torch>=2.0.0",
    "torchvision>=0.15.0"
  ],
  "isolatedPackages": [
    "ace-step @ git+https://github.com/ace-step/ACE-Step-1.5.git"
  ],
  "supportedModels": [
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "google/gemma-4-4b-it",
    "mlx-community/Qwen3.5-2B-MLX-4bit",
    "black-forest-labs/FLUX.2-klein-4B",
    "kugelaudio/kugelaudio-0-open",
    "ACE-Step/acestep-v15-turbo-continuous",
    "ACE-Step/acestep-v15-xl-turbo"
  ]
}
EOF

echo "Step 7: Verifying installation..."
"${OUTPUT_DIR}/venv/bin/python" -c "
import sys
import importlib.metadata as metadata
print(f'Python: {sys.version}')

import mlx
print(f'mlx: {metadata.version(\"mlx\")}')

from mlx_vlm import load
print('mlx-vlm: OK')

from mlx_audio.tts.utils import load_model
print('mlx-audio: OK')

import mflux
print('mflux: OK')

print('All dependencies verified!')
"

"${OUTPUT_DIR}/acestep-venv/bin/python" -c "
from acestep.inference import GenerationConfig, GenerationParams, generate_music
print('ACE-Step: OK')
"

echo ""
echo "=== Build Complete ==="
echo "Runtime bundle created at: ${OUTPUT_DIR}"
echo "Size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo ""
echo "To use:"
echo "  1. The bundle is embedded in the app at MLXHub/Resources/runtime/macos-arm64"
echo "  2. Python executable: ${OUTPUT_DIR}/venv/bin/python3"
echo "  3. Test: ${OUTPUT_DIR}/venv/bin/python3 -c 'from mlx_vlm import load; print(\"OK\")'"
