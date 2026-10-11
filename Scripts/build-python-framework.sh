#!/bin/bash
set -euo pipefail

# Python 3.12 security releases no longer ship macOS installers. Build the
# existing framework layout from verified sources, with OpenSSL linked statically.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/runtime-dependencies.sh"

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 BUILD_DIR CACHE_DIR FRAMEWORKS_DIR" >&2
    exit 2
fi
SOURCE_BUILD_DIR="$1"
SOURCE_CACHE_DIR="$2"
FRAMEWORKS_DIR="$3"
BUILD_JOBS="${MLXTRA_BUILD_JOBS:-8}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-arch arm64 -mmacosx-version-min=14.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
# Do not discover a developer's conda/Homebrew libraries or tools.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PKG_CONFIG=/usr/bin/false
unset PYTHONHOME PYTHONPATH CPPFLAGS CPATH LIBRARY_PATH DYLD_LIBRARY_PATH

download_verified_source() {
    local url="$1" destination="$2" expected="$3"
    if [ ! -f "${destination}" ]; then
        curl -fL --retry 3 --continue-at - -o "${destination}" "${url}"
    fi
    local actual
    actual="$(shasum -a 256 "${destination}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "Checksum mismatch for ${destination}; remove it and retry." >&2
        exit 1
    fi
}

mkdir -p "${SOURCE_BUILD_DIR}" "${SOURCE_CACHE_DIR}" "${FRAMEWORKS_DIR}"
download_verified_source "${PYTHON_URL}" "${SOURCE_CACHE_DIR}/${PYTHON_PKG_NAME}" "${PYTHON_PKG_SHA256}"
download_verified_source "${OPENSSL_URL}" "${SOURCE_CACHE_DIR}/openssl-${OPENSSL_VERSION}.tar.gz" "${OPENSSL_SHA256}"
download_verified_source "${XZ_URL}" "${SOURCE_CACHE_DIR}/xz-${XZ_VERSION}.tar.gz" "${XZ_SHA256}"
tar -xf "${SOURCE_CACHE_DIR}/${PYTHON_PKG_NAME}" -C "${SOURCE_BUILD_DIR}"
tar -xf "${SOURCE_CACHE_DIR}/openssl-${OPENSSL_VERSION}.tar.gz" -C "${SOURCE_BUILD_DIR}"
tar -xf "${SOURCE_CACHE_DIR}/xz-${XZ_VERSION}.tar.gz" -C "${SOURCE_BUILD_DIR}"

# macOS SDKs do not include liblzma headers. torchvision imports lzma, so
# provide a private static library rather than silently omitting Python's module.
XZ_PREFIX="${SOURCE_BUILD_DIR}/xz"
(
    cd "${SOURCE_BUILD_DIR}/xz-${XZ_VERSION}"
    ./configure --prefix="${XZ_PREFIX}" --disable-shared --enable-static \
        --disable-nls --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo
    make -j "${BUILD_JOBS}"
    make install
)

OPENSSL_PREFIX="${SOURCE_BUILD_DIR}/openssl"
(
    cd "${SOURCE_BUILD_DIR}/openssl-${OPENSSL_VERSION}"
    ./Configure darwin64-arm64-cc no-shared no-module no-tests \
        --prefix="${OPENSSL_PREFIX}" --openssldir=/etc/ssl
    make -j "${BUILD_JOBS}"
    make install_sw
)

PYTHON_STAGE="${SOURCE_BUILD_DIR}/python-stage"
(
    cd "${SOURCE_BUILD_DIR}/Python-${PYTHON_VERSION}"
    export LIBLZMA_CFLAGS="-I${XZ_PREFIX}/include"
    export LIBLZMA_LIBS="${XZ_PREFIX}/lib/liblzma.a"
    ./configure --enable-framework=/Library/Frameworks \
        --with-openssl="${OPENSSL_PREFIX}" --with-openssl-rpath=no \
        --disable-test-modules --with-ensurepip=no
    make -j "${BUILD_JOBS}"
    make frameworkinstall DESTDIR="${PYTHON_STAGE}"
)

cp -R "${PYTHON_STAGE}/Library/Frameworks/Python.framework/." "${FRAMEWORKS_DIR}/"
mkdir -p "${FRAMEWORKS_DIR}/Versions/3.12/Resources/licenses"
cp "${SOURCE_BUILD_DIR}/Python-${PYTHON_VERSION}/LICENSE" \
    "${FRAMEWORKS_DIR}/Versions/3.12/Resources/licenses/Python.txt"
cp "${SOURCE_BUILD_DIR}/openssl-${OPENSSL_VERSION}/LICENSE.txt" \
    "${FRAMEWORKS_DIR}/Versions/3.12/Resources/licenses/OpenSSL.txt"
cp "${SOURCE_BUILD_DIR}/xz-${XZ_VERSION}/COPYING" \
    "${FRAMEWORKS_DIR}/Versions/3.12/Resources/licenses/XZ.txt"
cp "${SOURCE_BUILD_DIR}/xz-${XZ_VERSION}/COPYING.0BSD" \
    "${FRAMEWORKS_DIR}/Versions/3.12/Resources/licenses/XZ-0BSD.txt"
echo "Built Python ${PYTHON_VERSION} with static OpenSSL ${OPENSSL_VERSION}"
