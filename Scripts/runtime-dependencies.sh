#!/bin/bash

# Shared runtime dependency pins for the embedded macOS Python bundle.
# Keep runtime upgrades here so the builder, validator, and generated manifest stay in sync.

RUNTIME_VERSION="0.1.0"
PYTHON_VERSION="3.12.8"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macos11.pkg"
PYTHON_PKG_NAME="python-${PYTHON_VERSION}-macos11.pkg"
PYTHON_PKG_SHA256="c411b5372d563532f5e6b589af7eb16e95613d61bd5af7bfe78563467130bbff"

MLX_VERSION="0.31.2"
MLX_VLM_VERSION="0.5.0"
MLX_AUDIO_VERSION="0.4.3"
MFLUX_VERSION="0.17.5"
TRANSFORMERS_VERSION="5.8.0"
HUGGINGFACE_HUB_VERSION="1.14.0"
PILLOW_VERSION="12.2.0"
NUMPY_VERSION="2.4.4"
TORCH_VERSION="2.11.0"
TORCHVISION_VERSION="0.26.0"
ACE_STEP_REF="6c1b2ef130bb7a7705a2abc61c11a258202b9ed2"
ACE_STEP_PACKAGE="git+https://github.com/ace-step/ACE-Step-1.5.git@${ACE_STEP_REF}"

RUNTIME_MAIN_PYPI_PACKAGES=(
    "mlx==${MLX_VERSION}"
    "mlx-vlm==${MLX_VLM_VERSION}"
    "mlx-audio==${MLX_AUDIO_VERSION}"
    "mflux==${MFLUX_VERSION}"
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
    "${RUNTIME_MAIN_PYPI_PACKAGES[@]}"
    "${RUNTIME_TORCH_PACKAGES[@]}"
)

RUNTIME_SUPPORTED_BACKENDS=(
    "vlm"
    "llm"
    "image"
    "audio"
    "music"
)

RUNTIME_CAPABILITIES=(
    "chat"
    "vision"
    "image-generation"
    "image-editing"
    "speech-generation"
    "music-generation"
)

RUNTIME_SUPPORTED_MODELS=(
    "mlx-community/Qwen3.5-9B-MLX-4bit"
    "google/gemma-4-e4b-it"
    "mlx-community/Qwen3.5-2B-MLX-4bit"
    "mlx-community/gemma-4-e2b-it-4bit"
    "mlx-community/gemma-4-26b-a4b-it-4bit"
    "mlx-community/Qwen3.6-27B-4bit"
    "mlx-community/Qwen3.6-35B-A3B-4bit"
    "black-forest-labs/FLUX.2-klein-4B"
    "kugelaudio/kugelaudio-0-open"
    "ACE-Step/acestep-v15-turbo-continuous"
)
