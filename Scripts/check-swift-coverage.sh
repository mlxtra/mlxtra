#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
THRESHOLD="${MLXTRA_CORE_COVERAGE_MIN:-80}"

# Gate the deterministic, unit-testable Swift core. UI views, app entrypoints,
# subprocess/runtime orchestration, network adapters, cache wrappers, renderer
# adapters, and debug instrumentation are still built and tested where practical,
# but they are not counted in the core line coverage threshold.
IGNORE_REGEX='/.build/|/Tests/|/Views/|MLXtraApp\.swift|UITestSupport\.swift|Services/Execution/VLM/VLMExecutor\.swift|Services/MCP/MCPWebSearchService\.swift|Services/Runtime/DownloadHelperProcessRunner\.swift|Services/Runtime/RuntimeManager\.swift|Services/Runtime/ModelDownloadManager\.swift|Utilities/AudioPlayerCache\.swift|Utilities/ImageCache\.swift|Utilities/MarkdownAttributedRenderer\.swift|Utilities/StreamingMarkdownInstrumentation\.swift'

cd "${PROJECT_DIR}"

swift test --enable-code-coverage

BUILD_DIR="$(swift build --show-bin-path)"
PROFILE="${BUILD_DIR}/codecov/default.profdata"
TEST_BINARY="${BUILD_DIR}/MLXtraPackageTests.xctest/Contents/MacOS/MLXtraPackageTests"

if [ ! -f "${PROFILE}" ]; then
    echo "error: Swift coverage profile not found at ${PROFILE}" >&2
    exit 1
fi

if [ ! -x "${TEST_BINARY}" ]; then
    echo "error: Swift test binary not found at ${TEST_BINARY}" >&2
    exit 1
fi

REPORT="$(xcrun llvm-cov report "${TEST_BINARY}" -instr-profile "${PROFILE}" -ignore-filename-regex="${IGNORE_REGEX}")"
printf '%s\n' "${REPORT}"

LINE_COVERAGE="$(printf '%s\n' "${REPORT}" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
if [ -z "${LINE_COVERAGE}" ]; then
    echo "error: Could not parse total line coverage from llvm-cov report" >&2
    exit 1
fi

python3 - "${LINE_COVERAGE}" "${THRESHOLD}" <<'PY'
import sys

coverage = float(sys.argv[1])
threshold = float(sys.argv[2])

if coverage < threshold:
    raise SystemExit(
        f"Core Swift line coverage {coverage:.2f}% is below required {threshold:.2f}%"
    )

print(f"Core Swift line coverage {coverage:.2f}% meets required {threshold:.2f}%")
PY
