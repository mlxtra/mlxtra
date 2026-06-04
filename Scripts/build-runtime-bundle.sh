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
MUSIC_OUTPUT_DIR="${PROJECT_DIR}/MLXtra/Resources/runtime/music-macos-arm64"
MUSIC_OUTPUT_DIR_EXPLICIT=0
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
  --music-output-dir PATH
                       Music runtime component output directory. Default: sibling music-macos-arm64.
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
        --music-output-dir)
            require_option_value "$1" "${2:-}"
            MUSIC_OUTPUT_DIR="$2"
            MUSIC_OUTPUT_DIR_EXPLICIT=1
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
if [ "${MUSIC_OUTPUT_DIR_EXPLICIT}" = "0" ]; then
    MUSIC_OUTPUT_DIR="$(dirname "${OUTPUT_DIR}")/music-macos-arm64"
fi
MUSIC_OUTPUT_DIR="$(absolute_path "${MUSIC_OUTPUT_DIR}")"
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
export PIP_NO_COMPILE=1
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

"${VENV_PIP}" install --no-compile --upgrade pip

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
    --no-compile \
    --no-index \
    --find-links "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"

for package in "${RUNTIME_MAIN_INSTALL_PACKAGES[@]}"; do
    echo "Installing ${package}..."
    "${VENV_PIP}" install --no-compile "${package}"
done

for package in "${RUNTIME_TORCH_PACKAGES[@]}"; do
    echo "Installing ${package}..."
    "${VENV_PIP}" install --no-compile "${package}" --index-url https://download.pytorch.org/whl/cpu
done

echo "Step 5: Creating runtime structure..."
mkdir -p "${OUTPUT_DIR}"
ACE_DOWNLOAD_HELPER_CACHE="${BUILD_DIR}/acestep_download_helper.py"
for helper_source in \
    "${PROJECT_DIR}/MLXtra/Resources/runtime/macos-arm64/acestep_download_helper.py" \
    "${PROJECT_DIR}/MLXtra/Resources/runtime/music-macos-arm64/acestep_download_helper.py" \
    "${MUSIC_OUTPUT_DIR}/acestep_download_helper.py"
do
    if [ -f "${helper_source}" ]; then
        cp -f "${helper_source}" "${ACE_DOWNLOAD_HELPER_CACHE}"
        break
    fi
done
rm -rf "${OUTPUT_DIR}/venv" "${OUTPUT_DIR}/python" "${OUTPUT_DIR}/shared" "${OUTPUT_DIR}/acestep-venv" "${OUTPUT_DIR}/magenta-venv" "${OUTPUT_DIR}/acestep_download_helper.py" "${OUTPUT_DIR}/runtime-music-manifest.json"
rm -rf "${MUSIC_OUTPUT_DIR}"

# Copy Python framework first so venv interpreter links can be made relative to it.
mkdir -p "${OUTPUT_DIR}/python"
if [ -d "${BUILD_DIR}/python/Frameworks" ]; then
    cp -R "${BUILD_DIR}/python/Frameworks" "${OUTPUT_DIR}/python/"
fi
remove_external_symlinks "${OUTPUT_DIR}/python/Frameworks" "${OUTPUT_DIR}"

cp -R "${BUILD_DIR}/venv" "${OUTPUT_DIR}/venv"

ACE_DOWNLOAD_HELPER_SOURCE="${ACE_DOWNLOAD_HELPER_CACHE}"
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
"${ACE_PIP}" install --no-compile --upgrade pip
echo "Installing ACE-Step MLX wheels for ${RUNTIME_MLX_WHEEL_PLATFORM}..."
"${ACE_PIP}" install \
    --no-compile \
    --no-index \
    --find-links "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"
"${ACE_PIP}" install --no-compile "${ACE_STEP_PACKAGE}"
cp -R "${BUILD_DIR}/acestep-venv" "${OUTPUT_DIR}/acestep-venv"

echo "Creating isolated Magenta RealTime 2 runtime..."
create_build_venv "${BUILD_DIR}/magenta-venv"
MAGENTA_PIP="${BUILD_DIR}/magenta-venv/bin/pip"
"${MAGENTA_PIP}" install --no-compile --upgrade pip
echo "Installing Magenta MLX wheels for ${RUNTIME_MLX_WHEEL_PLATFORM}..."
"${MAGENTA_PIP}" install \
    --no-compile \
    --no-index \
    --find-links "${FORCED_WHEELHOUSE}" \
    "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}"
"${MAGENTA_PIP}" install --no-compile "${MAGENTA_RT_PACKAGE}"
cp -R "${BUILD_DIR}/magenta-venv" "${OUTPUT_DIR}/magenta-venv"

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

    [ -d "${target_dir}" ] || return 0
    while IFS= read -r -d '' binary; do
        codesign --force --sign - "${binary}" 2>/dev/null || true
    done < <(find "${target_dir}" -type f \( -name "*.so" -o -name "*.dylib" \) -print0)
}

prune_runtime_tree() {
    local root_dir="$1"

    /usr/bin/python3 - "${root_dir}" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
if not root.exists():
    raise SystemExit(0)

removed_files = 0
removed_dirs = 0
for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    name = path.name
    if path.is_dir():
        if name == "__pycache__" or (
            name in {"test", "tests"}
            and "site-packages" in path.parts
        ):
            shutil.rmtree(path, ignore_errors=True)
            removed_dirs += 1
        continue
    if path.is_file() and (name.endswith((".pyc", ".pyo", ".h"))):
        path.unlink(missing_ok=True)
        removed_files += 1

print(f"Pruned {removed_files} files and {removed_dirs} directories from {root}")
PY
}

dedupe_shared_site_packages() {
    local runtime_root="$1"
    local main_site_packages="${runtime_root}/venv/lib/python3.12/site-packages"
    local ace_site_packages="${runtime_root}/acestep-venv/lib/python3.12/site-packages"
    local shared_site_packages="${runtime_root}/shared/lib/python3.12/site-packages"

    /usr/bin/python3 - "${main_site_packages}" "${ace_site_packages}" "${shared_site_packages}" <<'PY'
import csv
import filecmp
import os
import pathlib
import shutil
import sys

main_site = pathlib.Path(sys.argv[1])
ace_site = pathlib.Path(sys.argv[2])
shared_site = pathlib.Path(sys.argv[3])

if not main_site.is_dir() or not ace_site.is_dir():
    raise SystemExit(0)

allowed = {
    "aiohttp", "anyio", "attrs", "certifi", "cffi", "charset-normalizer",
    "click", "contourpy", "cycler", "fastapi", "filelock", "fonttools",
    "frozenlist", "fsspec", "hf-xet", "httpcore", "httpx", "idna",
    "jinja2", "kiwisolver", "matplotlib", "mlx", "mlx-metal", "mpmath",
    "multidict", "networkx", "numpy", "packaging", "pillow", "protobuf",
    "pydantic", "pydantic-core", "pygments", "pyparsing", "python-dateutil",
    "pyyaml", "regex", "requests", "rich", "safetensors", "scipy",
    "sentencepiece", "six", "sniffio", "starlette", "sympy", "tokenizers",
    "torch", "torchvision", "tqdm", "typing-extensions", "urllib3", "uvicorn",
    "yarl",
}


def norm(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def metadata_for(dist_info: pathlib.Path):
    metadata = dist_info / "METADATA"
    if not metadata.is_file():
        return None
    name = None
    version = None
    for line in metadata.read_text(errors="ignore").splitlines():
        if line.startswith("Name: "):
            name = line.removeprefix("Name: ").strip()
        elif line.startswith("Version: "):
            version = line.removeprefix("Version: ").strip()
    if not name or not version:
        return None
    return norm(name), version


def record_tops(dist_info: pathlib.Path):
    tops = {dist_info.name}
    record = dist_info / "RECORD"
    if not record.is_file():
        return tops
    with record.open(newline="", errors="ignore") as handle:
        for row in csv.reader(handle):
            if not row:
                continue
            rel = row[0]
            if not rel or rel.startswith("../"):
                continue
            top = rel.split("/", 1)[0]
            if top and top not in {"bin", "__pycache__"}:
                tops.add(top)
    return tops


def same_path(lhs: pathlib.Path, rhs: pathlib.Path) -> bool:
    if lhs.is_symlink() or rhs.is_symlink():
        return lhs.is_symlink() and rhs.is_symlink() and os.readlink(lhs) == os.readlink(rhs)
    if lhs.is_file() and rhs.is_file():
        return filecmp.cmp(lhs, rhs, shallow=False)
    if lhs.is_dir() and rhs.is_dir():
        lhs_entries = sorted(p.name for p in lhs.iterdir())
        rhs_entries = sorted(p.name for p in rhs.iterdir())
        if lhs_entries != rhs_entries:
            return False
        return all(same_path(lhs / name, rhs / name) for name in lhs_entries)
    return False


main_dists = {}
for dist in main_site.glob("*.dist-info"):
    info = metadata_for(dist)
    if info:
        main_dists[info[0]] = (info[1], dist)

candidate_tops = set()
for ace_dist in ace_site.glob("*.dist-info"):
    info = metadata_for(ace_dist)
    if not info:
        continue
    name, version = info
    main_info = main_dists.get(name)
    if name not in allowed or main_info is None or main_info[0] != version:
        continue
    candidate_tops.update(record_tops(main_info[1]))
    candidate_tops.update(record_tops(ace_dist))

shared_site.mkdir(parents=True, exist_ok=True)
linked = []
for top in sorted(candidate_tops):
    main_path = main_site / top
    ace_path = ace_site / top
    shared_path = shared_site / top
    if not main_path.exists() or not ace_path.exists():
        continue
    if main_path.is_symlink() or ace_path.is_symlink():
        continue
    if not same_path(main_path, ace_path):
        continue
    if shared_path.exists() and not same_path(shared_path, main_path):
        continue
    if not shared_path.exists():
        if main_path.is_dir():
            shutil.copytree(main_path, shared_path, symlinks=True)
        else:
            shutil.copy2(main_path, shared_path, follow_symlinks=False)
    for site, path in ((main_site, main_path), (ace_site, ace_path)):
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        rel = os.path.relpath(shared_path, start=site)
        path.symlink_to(rel)
    linked.append(top)

if linked:
    print(f"Shared {len(linked)} duplicate package entries:")
    for top in linked:
        print(f"  {top}")
else:
    print("No duplicate package entries were shared.")
PY
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
relocate_venv "${OUTPUT_DIR}/magenta-venv"
prune_runtime_tree "${OUTPUT_DIR}/venv"
prune_runtime_tree "${OUTPUT_DIR}/acestep-venv"
prune_runtime_tree "${OUTPUT_DIR}/magenta-venv"
dedupe_shared_site_packages "${OUTPUT_DIR}"
codesign_native_artifacts "${OUTPUT_DIR}/venv"
codesign_native_artifacts "${OUTPUT_DIR}/acestep-venv"
codesign_native_artifacts "${OUTPUT_DIR}/magenta-venv"
codesign_native_artifacts "${OUTPUT_DIR}/shared"

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
validate_mlx_wheel_platform "${OUTPUT_DIR}/magenta-venv/lib/python3.12/site-packages"
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
  "component": "base",
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
  "isolatedPackages": [],
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

cat > "${OUTPUT_DIR}/runtime-music-manifest.json" << EOF
{
  "runtimeVersion": "${RUNTIME_VERSION}",
  "compatibilityApi": 1,
  "platform": "macos",
  "arch": "arm64",
  "component": "music",
  "channel": "stable",
  "pythonVersion": "${PYTHON_VERSION}",
  "pythonPath": "acestep-venv/bin/python3",
  "executables": {
    "python": "acestep-venv/bin/python3",
    "pip": "acestep-venv/bin/pip"
  },
  "packages": [
$(json_array_items 4 "${RUNTIME_FORCED_BINARY_PYPI_PACKAGES[@]}")
  ],
  "isolatedPackages": [
    "ace-step @ ${ACE_STEP_PACKAGE}",
    "${MAGENTA_RT_PACKAGE}"
  ],
  "supportedBackends": [
$(json_array_items 4 "${RUNTIME_MUSIC_SUPPORTED_BACKENDS[@]}")
  ],
  "capabilities": [
$(json_array_items 4 "${RUNTIME_MUSIC_CAPABILITIES[@]}")
  ]
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

RUNTIME_MLX_METAL_VERSION="${MLX_METAL_VERSION}" \
PYTHONHOME="${RUNTIME_PYTHONHOME}" PYTHONDONTWRITEBYTECODE=1 "${OUTPUT_DIR}/magenta-venv/bin/python" -c "
import importlib.metadata as metadata
from magenta_rt import MagentaRT2Mlxfn
print('Magenta RealTime 2: OK')
print('magenta-rt: ' + metadata.version('magenta-rt'))
mlx_metal = metadata.version('mlx-metal')
if mlx_metal != '${MLX_METAL_VERSION}':
    raise RuntimeError(f'mlx-metal version mismatch: expected ${MLX_METAL_VERSION}, got {mlx_metal}')
print('Magenta mlx-metal: ' + mlx_metal)
"
fi

echo "Step 8: Splitting music runtime component..."
mkdir -p "${MUSIC_OUTPUT_DIR}"
mv "${OUTPUT_DIR}/acestep-venv" "${MUSIC_OUTPUT_DIR}/acestep-venv"
mv "${OUTPUT_DIR}/magenta-venv" "${MUSIC_OUTPUT_DIR}/magenta-venv"
mv "${OUTPUT_DIR}/acestep_download_helper.py" "${MUSIC_OUTPUT_DIR}/acestep_download_helper.py"
mv "${OUTPUT_DIR}/runtime-music-manifest.json" "${MUSIC_OUTPUT_DIR}/runtime-music-manifest.json"
validate_self_contained_symlinks "${OUTPUT_DIR}"
validate_self_contained_symlinks "${MUSIC_OUTPUT_DIR}"

echo ""
echo "=== Build Complete ==="
echo "Base runtime bundle created at: ${OUTPUT_DIR}"
echo "Base size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo "Music runtime component created at: ${MUSIC_OUTPUT_DIR}"
echo "Music component size: $(du -sh "${MUSIC_OUTPUT_DIR}" | cut -f1)"
echo ""
echo "To use:"
echo "  1. Publish it as a runtime-macos-arm64-<version>.zip GitHub release asset"
echo "  2. Publish ${MUSIC_OUTPUT_DIR} as runtime-music-macos-arm64-<version>.zip"
echo "  3. Reference both assets from MLXtra/Resources/stable-channel.json"
echo "  4. Python executable: ${OUTPUT_DIR}/venv/bin/python3"
echo "  5. Test: PYTHONHOME=${OUTPUT_DIR}/python/Frameworks/Versions/3.12 ${OUTPUT_DIR}/venv/bin/python3 -c 'import csv; print(\"OK\")'"
