#!/bin/bash

# Shared runtime dependency pins for the embedded macOS Python bundle.
# Keep runtime upgrades here so the builder, validator, and generated manifest stay in sync.

RUNTIME_DEPENDENCIES_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
RUNTIME_DEPENDENCY_LOCK_FILE="${RUNTIME_DEPENDENCIES_DIR}/runtime-locks/macos-arm64.lock.json"
RUNTIME_DEPENDENCY_LOCK_VALIDATOR="${RUNTIME_DEPENDENCIES_DIR}/runtime-locks/validate-runtime-lock.py"

RUNTIME_VERSION="0.1.10"
PYTHON_VERSION="3.12.15"
# Security releases of Python 3.12 are source-only. Build an arm64 framework
# with a private OpenSSL instead of using a developer-local interpreter/library.
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
PYTHON_PKG_NAME="Python-${PYTHON_VERSION}.tar.xz"
PYTHON_PKG_SHA256="c2c4321961fab0fb999d66e0cecf521c2ab3994c7992873ea99e306c1094fd5a"
OPENSSL_VERSION="3.5.9"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
XZ_VERSION="5.8.4"
XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
XZ_SHA256="0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9"

MLX_VERSION="0.32.3"
MLX_METAL_VERSION="0.32.3"
MLX_VLM_VERSION="0.7.6"
MLX_AUDIO_VERSION="0.5.8"
MISAKI_VERSION="0.9.4"
EN_CORE_WEB_SM_VERSION="3.8.0"
# Ship English phonemization data; Misaki otherwise installs it on first use.
EN_CORE_WEB_SM_PACKAGE="en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-${EN_CORE_WEB_SM_VERSION}/en_core_web_sm-${EN_CORE_WEB_SM_VERSION}-py3-none-any.whl#sha256=1932429db727d4bff3deed6b34cfc05df17794f4a52eeb26cf8928f7c1a0fb85"
MFLUX_VERSION="0.22.0"
MFLUX_REF="31c9640399572ea394d07092763be9a36007a754"
MFLUX_PACKAGE="mflux==${MFLUX_VERSION}"
TRANSFORMERS_VERSION="5.19.0"
# MFLUX requires Hub <2.0.
HUGGINGFACE_HUB_VERSION="1.33.0"
PILLOW_VERSION="12.3.0"
NUMPY_VERSION="2.4.4"
TORCH_VERSION="2.14.1"
TORCHVISION_VERSION="0.29.1"
ACE_STEP_REF="dce621408bee8c31b4fcf4811682eb9359e1bc94"
ACE_STEP_PACKAGE="git+https://github.com/ace-step/ACE-Step-1.5.git@${ACE_STEP_REF}"
# Published .mlxfn models use the MLX 0.31 serialization format.
MAGENTA_MLX_VERSION="0.31.2"
MAGENTA_RT_VERSION="2.0.3"
MAGENTA_RT_PACKAGE="magenta-rt[mlx]==${MAGENTA_RT_VERSION}"
RUNTIME_MLX_WHEEL_PLATFORM="macosx_14_0_arm64"

RUNTIME_FORCED_BINARY_PYPI_PACKAGES=(
    "mlx==${MLX_VERSION}"
    "mlx-metal==${MLX_METAL_VERSION}"
)

RUNTIME_MAGENTA_BINARY_PACKAGES=(
    "mlx==${MAGENTA_MLX_VERSION}"
    "mlx-metal==${MAGENTA_MLX_VERSION}"
)

RUNTIME_MAIN_PYPI_PACKAGES=(
    "mlx-vlm==${MLX_VLM_VERSION}"
    "mlx-audio==${MLX_AUDIO_VERSION}"
    "misaki[en]==${MISAKI_VERSION}"
    "en-core-web-sm==${EN_CORE_WEB_SM_VERSION}"
    "mflux==${MFLUX_VERSION}"
    "transformers==${TRANSFORMERS_VERSION}"
    "huggingface-hub==${HUGGINGFACE_HUB_VERSION}"
    "pillow==${PILLOW_VERSION}"
    "numpy==${NUMPY_VERSION}"
)

RUNTIME_MAIN_INSTALL_PACKAGES=(
    "mlx-vlm==${MLX_VLM_VERSION}"
    "mlx-audio==${MLX_AUDIO_VERSION}"
    "misaki[en]==${MISAKI_VERSION}"
    "${EN_CORE_WEB_SM_PACKAGE}"
    "${MFLUX_PACKAGE}"
    "transformers==${TRANSFORMERS_VERSION}"
    "huggingface-hub==${HUGGINGFACE_HUB_VERSION}"
    "pillow==${PILLOW_VERSION}"
    "numpy==${NUMPY_VERSION}"
)

RUNTIME_TORCH_PACKAGES=(
    "torch==${TORCH_VERSION}"
    "torchvision==${TORCHVISION_VERSION}"
)

RUNTIME_MAIN_PACKAGES=(
    "mlx==${MLX_VERSION}"
    "${RUNTIME_MAIN_PYPI_PACKAGES[@]}"
    "${RUNTIME_TORCH_PACKAGES[@]}"
)

RUNTIME_SUPPORTED_BACKENDS=(
    "vlm"
    "llm"
    "image"
    "audio"
)

RUNTIME_CAPABILITIES=(
    "chat"
    "vision"
    "image-generation"
    "image-editing"
    "speech-generation"
)

RUNTIME_MUSIC_SUPPORTED_BACKENDS=(
    "music"
)

RUNTIME_MUSIC_CAPABILITIES=(
    "music-generation"
    "realtime-music"
)

RUNTIME_MFLUX_CONFIGS=(
    "flux2-klein-4b"
    "ideogram-4-fp8"
    "z-image-turbo"
)

RUNTIME_MFLUX_CLASSES=(
    "Flux2Klein"
    "Flux2KleinEdit"
    "Ideogram4"
    "ZImage"
    "ZImageTurbo"
)

RUNTIME_MFLUX_QUANTIZE_BITS=(
    "3"
    "4"
    "5"
    "6"
    "8"
)

RUNTIME_AUDIO_ADAPTERS=(
    "kugelaudio"
    "kokoro"
    "higgs-audio-v3"
)

validate_runtime_dependency_lock() {
    /usr/bin/python3 "${RUNTIME_DEPENDENCY_LOCK_VALIDATOR}" \
        --dependencies "${RUNTIME_DEPENDENCIES_DIR}/runtime-dependencies.sh" \
        --lock-file "${RUNTIME_DEPENDENCY_LOCK_FILE}"
}
