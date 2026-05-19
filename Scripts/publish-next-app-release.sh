#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_FILE="${PROJECT_DIR}/MLXtra.xcodeproj/project.pbxproj"
PUBLISH_SCRIPT="${SCRIPT_DIR}/publish-app-release.sh"

REQUESTED_VERSION=""
REQUESTED_BUILD=""
DRY_RUN=0
PUBLISH_ARGS=()

usage() {
    cat <<'USAGE'
Usage: Scripts/publish-next-app-release.sh [bump options] [publish options]

Bump the MLXtra app version/build, then run Scripts/publish-app-release.sh.

By default this script:
  - increments MARKETING_VERSION by one patch version
  - increments CURRENT_PROJECT_VERSION by 1
  - runs publish-app-release.sh with the remaining options

Bump options:
  --version version    Explicit next MARKETING_VERSION, for example 1.1.0
  --build number      Explicit next CURRENT_PROJECT_VERSION
  --dry-run           Print the bump and publish command without editing files
  -h, --help          Show this help.

All other options are passed through to publish-app-release.sh.

Examples:
  Scripts/publish-next-app-release.sh --repo mlxtra/mlxtra
  Scripts/publish-next-app-release.sh --version 1.1.0 --repo mlxtra/mlxtra
  Scripts/publish-next-app-release.sh --dry-run --repo mlxtra/mlxtra
  Scripts/publish-next-app-release.sh --skip-notarization --skip-publish
USAGE
}

require_option_value() {
    local option="$1"
    local value="${2:-}"

    if [ -z "${value}" ] || [[ "${value}" == --* ]]; then
        echo "${option} requires a value." >&2
        usage >&2
        exit 2
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            require_option_value "$1" "${2:-}"
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --build)
            require_option_value "$1" "${2:-}"
            REQUESTED_BUILD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                PUBLISH_ARGS+=("$1")
                shift
            done
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            PUBLISH_ARGS+=("$1")
            shift
            ;;
    esac
done

read_project_versions() {
    python3 - "${PROJECT_FILE}" <<'PY'
from pathlib import Path
import re
import sys

project_file = Path(sys.argv[1])
text = project_file.read_text()
versions = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
builds = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)

if not versions:
    sys.exit("No MARKETING_VERSION entries found in project.pbxproj")
if not builds:
    sys.exit("No CURRENT_PROJECT_VERSION entries found in project.pbxproj")

version_values = sorted(set(versions))
build_values = sorted(set(builds))

if len(version_values) != 1:
    sys.exit(f"Expected one MARKETING_VERSION value, found: {', '.join(version_values)}")
if len(build_values) != 1:
    sys.exit(f"Expected one CURRENT_PROJECT_VERSION value, found: {', '.join(build_values)}")

print(version_values[0], build_values[0])
PY
}

next_patch_version() {
    python3 - "$1" <<'PY'
import re
import sys

version = sys.argv[1]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    sys.exit(f"Current MARKETING_VERSION must be numeric x.y.z for automatic patch bump, found: {version}")

major, minor, patch = (int(part) for part in version.split("."))
print(f"{major}.{minor}.{patch + 1}")
PY
}

validate_next_values() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re
import sys

current_version, current_build, next_version, next_build = sys.argv[1:5]

if not re.fullmatch(r"\d+\.\d+\.\d+", next_version):
    sys.exit(f"Next MARKETING_VERSION must be numeric x.y.z, found: {next_version}")
if not re.fullmatch(r"\d+", current_build):
    sys.exit(f"Current CURRENT_PROJECT_VERSION must be an integer, found: {current_build}")
if not re.fullmatch(r"\d+", next_build):
    sys.exit(f"Next CURRENT_PROJECT_VERSION must be an integer, found: {next_build}")

current_version_tuple = tuple(int(part) for part in current_version.split("."))
next_version_tuple = tuple(int(part) for part in next_version.split("."))

if next_version_tuple <= current_version_tuple:
    sys.exit(f"Next MARKETING_VERSION must be greater than {current_version}, found: {next_version}")
if int(next_build) <= int(current_build):
    sys.exit(f"Next CURRENT_PROJECT_VERSION must be greater than {current_build}, found: {next_build}")
PY
}

update_project_versions() {
    python3 - "${PROJECT_FILE}" "$1" "$2" "$3" "$4" <<'PY'
from pathlib import Path
import re
import sys

project_file = Path(sys.argv[1])
current_version, current_build, next_version, next_build = sys.argv[2:6]
text = project_file.read_text()

text, version_count = re.subn(
    rf"(MARKETING_VERSION = ){re.escape(current_version)};",
    rf"\g<1>{next_version};",
    text,
)
text, build_count = re.subn(
    rf"(CURRENT_PROJECT_VERSION = ){re.escape(current_build)};",
    rf"\g<1>{next_build};",
    text,
)

if version_count == 0:
    sys.exit("No MARKETING_VERSION entries were updated")
if build_count == 0:
    sys.exit("No CURRENT_PROJECT_VERSION entries were updated")

project_file.write_text(text)
print(f"Updated {version_count} MARKETING_VERSION entries and {build_count} CURRENT_PROJECT_VERSION entries.")
PY
}

print_command() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
}

require_command python3

if [ ! -f "${PROJECT_FILE}" ]; then
    echo "Project file not found: ${PROJECT_FILE}" >&2
    exit 1
fi

if [ ! -x "${PUBLISH_SCRIPT}" ]; then
    echo "Publish script is not executable: ${PUBLISH_SCRIPT}" >&2
    exit 1
fi

read -r CURRENT_VERSION CURRENT_BUILD < <(read_project_versions)

NEXT_VERSION="${REQUESTED_VERSION}"
if [ -z "${NEXT_VERSION}" ]; then
    NEXT_VERSION="$(next_patch_version "${CURRENT_VERSION}")"
fi

NEXT_BUILD="${REQUESTED_BUILD}"
if [ -z "${NEXT_BUILD}" ]; then
    if ! [[ "${CURRENT_BUILD}" =~ ^[0-9]+$ ]]; then
        echo "Current CURRENT_PROJECT_VERSION must be an integer, found: ${CURRENT_BUILD}" >&2
        exit 1
    fi
    NEXT_BUILD="$((CURRENT_BUILD + 1))"
fi

validate_next_values "${CURRENT_VERSION}" "${CURRENT_BUILD}" "${NEXT_VERSION}" "${NEXT_BUILD}"

echo "Current app version: ${CURRENT_VERSION} (${CURRENT_BUILD})"
echo "Next app version:    ${NEXT_VERSION} (${NEXT_BUILD})"

if [ "${DRY_RUN}" = "1" ]; then
    echo ""
    echo "Dry run only. No files changed and no release was published."
    print_command "${PUBLISH_SCRIPT}" "${PUBLISH_ARGS[@]}"
    exit 0
fi

update_project_versions "${CURRENT_VERSION}" "${CURRENT_BUILD}" "${NEXT_VERSION}" "${NEXT_BUILD}"
print_command "${PUBLISH_SCRIPT}" "${PUBLISH_ARGS[@]}"
"${PUBLISH_SCRIPT}" "${PUBLISH_ARGS[@]}"
