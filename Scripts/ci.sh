#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/runtime-dependencies.sh"

cd "${PROJECT_DIR}"

usage() {
    cat <<'USAGE'
Usage: Scripts/ci.sh [step ...]

Runs the same checks used by .github/workflows/ci.yml.
With no steps, runs the full CI sequence.

Steps:
  xcode-version       Print the active Xcode version
  metadata            Validate release metadata
  py-compile          Compile Python scripts used by CI
  runtime-archive     Validate staged runtime release archive(s), if present
  python-tests        Run Python bridge unit tests
  swift-coverage      Run Swift tests with the core coverage gate
  build-app           Build the app shell with runtime validation skipped
  all                 Run every step
USAGE
}

run_xcode_version() {
    xcodebuild -version
}

run_metadata() {
    python3 Scripts/validate-release-metadata.py --allow-runtime-version-drift
}

run_py_compile() {
    python3 -m py_compile \
        MLXtra/Resources/python_bridge.py \
        MLXtra/Resources/acestep_bridge.py \
        MLXtra/Resources/bridge_utils.py \
        MLXtra/Resources/runtime/macos-arm64/acestep_download_helper.py \
        Scripts/validate-release-metadata.py \
        Tests/IntegrationTests/test_all_models_integration.py \
        Tests/IntegrationTests/test_bridge.py \
        Tests/IntegrationTests/test_music_bridge.py \
        Tests/IntegrationTests/test_music_generation.py \
        Tests/IntegrationTests/test_music_integration.py
}

run_runtime_archive() {
    local archive=".build/release/runtime-macos-arm64-${RUNTIME_VERSION}.zip"
    if [ ! -e "${archive}" ]; then
        echo "No staged runtime release archive found; skipping runtime archive validation."
        return 0
    fi

    Scripts/validate-runtime-release-archive.sh \
        --expected-version "${RUNTIME_VERSION}" \
        "${archive}"
}

run_python_tests() {
    (
        cd Tests/PythonTests
        PYTHONPATH=../../../MLXtra/Resources python3 -m unittest discover -v
    )
}

run_swift_coverage() {
    MLXTRA_CORE_COVERAGE_MIN="${MLXTRA_CORE_COVERAGE_MIN:-80}" \
        Scripts/check-swift-coverage.sh
}

run_build_app() {
    MLXTRA_SKIP_RUNTIME_VALIDATION="${MLXTRA_SKIP_RUNTIME_VALIDATION:-1}" \
        xcodebuild \
        -project MLXtra.xcodeproj \
        -scheme MLXtra \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        build
}

run_step() {
    case "$1" in
        xcode-version)
            run_xcode_version
            ;;
        metadata)
            run_metadata
            ;;
        py-compile)
            run_py_compile
            ;;
        runtime-archive)
            run_runtime_archive
            ;;
        python-tests)
            run_python_tests
            ;;
        swift-coverage)
            run_swift_coverage
            ;;
        build-app)
            run_build_app
            ;;
        all)
            run_all
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "error: unknown CI step '$1'" >&2
            usage >&2
            return 2
            ;;
    esac
}

run_all() {
    run_xcode_version
    run_metadata
    run_py_compile
    run_runtime_archive
    run_python_tests
    run_swift_coverage
    run_build_app
}

if [ "$#" -eq 0 ]; then
    run_all
else
    for step in "$@"; do
        run_step "${step}"
    done
fi
