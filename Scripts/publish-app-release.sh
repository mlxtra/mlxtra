#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

REPOSITORY="mlxtra/mlxtra"
APPCAST_TAG="appcast-stable"
OUTPUT_DIR="${PROJECT_DIR}/.build/app-release"
SPARKLE_ACCOUNT="mlxtra"
SPARKLE_PUBLIC_KEY="${MLXTRA_SPARKLE_PUBLIC_ED_KEY:-}"
SIGNING_IDENTITY="${MLXTRA_DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${MLXTRA_DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${MLXTRA_NOTARY_KEYCHAIN_PROFILE:-mlxtra-notary}"
NOTARY_APPLE_ID="${MLXTRA_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${MLXTRA_NOTARY_PASSWORD:-}"
RELEASE_NOTES_PATH=""
SETUP_NOTARY=0
SKIP_NOTARIZATION=0
SKIP_PUBLISH=0
FORCE=0
ALLOW_PRIVATE=0

usage() {
    cat <<'USAGE'
Usage: Scripts/publish-app-release.sh [options]

Build, sign, notarize, package, appcast, and publish an MLXtra app release.

The script publishes:
  - app-<version> release with MLXtra-<version>.dmg
  - appcast-stable release with appcast.xml and release notes for Sparkle

Options:
  --repo owner/name                GitHub repository. Default: mlxtra/mlxtra
  --appcast-tag tag                Moving appcast release tag. Default: appcast-stable
  --output-dir path                Working/output directory. Default: .build/app-release
  --sparkle-account name           Sparkle Keychain account. Default: mlxtra
  --public-key key                 Sparkle public EdDSA key. Default: read from Keychain
  --signing-identity identity      Developer ID Application identity. Default: auto-detect
  --team-id id                     Apple Developer Team ID. Default: infer from identity
  --notary-keychain-profile name   notarytool keychain profile. Default: mlxtra-notary
  --setup-notary                   Store/update the notary profile before publishing
  --apple-id email                 Apple ID for --setup-notary
  --release-notes path             Markdown/HTML/text release notes for Sparkle
  --skip-notarization              Local-only builds; cannot publish unless --skip-publish is also set
  --skip-publish                   Build local artifacts without uploading to GitHub
  --force                          Replace existing DMG asset on app-<version>
  --allow-private                  Permit publishing to a private repo for internal testing
  -h, --help                       Show this help.

Environment equivalents:
  MLXTRA_SPARKLE_PUBLIC_ED_KEY
  MLXTRA_DEVELOPER_ID_APPLICATION
  MLXTRA_DEVELOPMENT_TEAM
  MLXTRA_NOTARY_KEYCHAIN_PROFILE
  MLXTRA_NOTARY_APPLE_ID
  MLXTRA_NOTARY_PASSWORD

The private Sparkle key is read from the macOS Keychain using --sparkle-account.
Do not export or commit the private key.
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

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            require_option_value "$1" "${2:-}"
            REPOSITORY="$2"
            shift 2
            ;;
        --appcast-tag)
            require_option_value "$1" "${2:-}"
            APPCAST_TAG="$2"
            shift 2
            ;;
        --output-dir)
            require_option_value "$1" "${2:-}"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --sparkle-account)
            require_option_value "$1" "${2:-}"
            SPARKLE_ACCOUNT="$2"
            shift 2
            ;;
        --public-key)
            require_option_value "$1" "${2:-}"
            SPARKLE_PUBLIC_KEY="$2"
            shift 2
            ;;
        --signing-identity)
            require_option_value "$1" "${2:-}"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --team-id)
            require_option_value "$1" "${2:-}"
            TEAM_ID="$2"
            shift 2
            ;;
        --notary-keychain-profile)
            require_option_value "$1" "${2:-}"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --setup-notary)
            SETUP_NOTARY=1
            shift
            ;;
        --apple-id)
            require_option_value "$1" "${2:-}"
            NOTARY_APPLE_ID="$2"
            shift 2
            ;;
        --release-notes)
            require_option_value "$1" "${2:-}"
            RELEASE_NOTES_PATH="$2"
            shift 2
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION=1
            shift
            ;;
        --skip-publish)
            SKIP_PUBLISH=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --allow-private)
            ALLOW_PRIVATE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

run_gh_write() {
    if [ "${SKIP_PUBLISH}" = "1" ]; then
        printf '+ skip-publish'
        printf ' %q' "$@"
        printf '\n'
        return
    fi

    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

build_setting() {
    local key="$1"
    xcodebuild -project "${PROJECT_DIR}/MLXtra.xcodeproj" \
        -scheme MLXtra \
        -configuration Release \
        -showBuildSettings 2>/dev/null \
        | awk -F '=' -v wanted="${key}" '$1 ~ wanted { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

file_size() {
    local path="$1"
    if stat -f%z "$path" >/dev/null 2>&1; then
        stat -f%z "$path"
    else
        stat -c%s "$path"
    fi
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

notary_json_value() {
    local key="$1"
    local path="$2"
    /usr/bin/plutil -extract "${key}" raw -o - "${path}" 2>/dev/null || true
}

detect_signing_identity() {
    local identities
    identities="$(security find-identity -v -p codesigning \
        | sed -nE 's/.*"([^"]*Developer ID Application[^"]*)".*/\1/p')"

    local identity_count
    identity_count="$(printf '%s\n' "${identities}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [ "${identity_count}" = "0" ]; then
        echo "No Developer ID Application signing identity was found." >&2
        echo "Install your Developer ID certificate, or pass --signing-identity." >&2
        exit 1
    fi

    if [ "${identity_count}" != "1" ]; then
        echo "Multiple Developer ID Application identities were found." >&2
        echo "Pass the intended one with --signing-identity:" >&2
        printf '%s\n' "${identities}" >&2
        exit 1
    fi

    printf '%s\n' "${identities}"
}

infer_team_id_from_identity() {
    printf '%s\n' "$1" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p'
}

store_notary_credentials() {
    if [ -z "${NOTARY_APPLE_ID}" ]; then
        echo "--setup-notary requires --apple-id or MLXTRA_NOTARY_APPLE_ID." >&2
        exit 2
    fi

    if [ -z "${TEAM_ID}" ]; then
        echo "Could not infer Apple Developer Team ID from signing identity." >&2
        echo "Pass --team-id or set MLXTRA_DEVELOPMENT_TEAM." >&2
        exit 1
    fi

    if [ -z "${NOTARY_PASSWORD}" ]; then
        if [ ! -t 0 ]; then
            echo "MLXTRA_NOTARY_PASSWORD is required when --setup-notary is used non-interactively." >&2
            exit 2
        fi

        read -rsp "App-specific password for ${NOTARY_APPLE_ID}: " NOTARY_PASSWORD
        echo
    fi

    echo "+ xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id ${NOTARY_APPLE_ID} --team-id ${TEAM_ID} --password ********"
    xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
        --apple-id "${NOTARY_APPLE_ID}" \
        --team-id "${TEAM_ID}" \
        --password "${NOTARY_PASSWORD}"
}

verify_notary_profile() {
    echo "+ xcrun notarytool history --keychain-profile ${NOTARY_PROFILE}"
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null; then
        echo "Notary keychain profile '${NOTARY_PROFILE}' is missing or invalid." >&2
        echo "Run with --setup-notary --apple-id <apple-id>, or pass --notary-keychain-profile with the profile you already created." >&2
        exit 1
    fi
}

prune_broken_symlinks() {
    local root="$1"
    local broken_symlink_count
    broken_symlink_count="$(find "${root}" -type l ! -exec test -e {} \; -print | wc -l | tr -d ' ')"

    if [ "${broken_symlink_count}" = "0" ]; then
        return
    fi

    echo "Pruning ${broken_symlink_count} broken symlink(s) from packaged app resources."
    find "${root}" -type l ! -exec test -e {} \; -print -delete
}

prune_packaging_artifacts() {
    local root="$1"
    local artifact_count
    artifact_count="$(find "${root}" -type f \( -name '*.a' -o -name '*.o' \) -print | wc -l | tr -d ' ')"

    if [ "${artifact_count}" = "0" ]; then
        return
    fi

    echo "Pruning ${artifact_count} static/object artifact(s) from packaged app resources."
    find "${root}" -type f \( -name '*.a' -o -name '*.o' \) -print -delete
}

codesign_path() {
    local path="$1"
    local preserve_metadata="${2:-0}"
    local codesign_args=(
        codesign
        --force
        --sign "${SIGNING_IDENTITY}"
        --options runtime
    )

    if [ "${SIGNING_IDENTITY}" != "-" ]; then
        codesign_args+=(--timestamp)
    fi

    if [ "${preserve_metadata}" = "1" ]; then
        codesign_args+=(--preserve-metadata=identifier,entitlements)
    fi

    codesign_args+=("${path}")

    if ! "${codesign_args[@]}"; then
        echo "Failed to sign: ${path}" >&2
        exit 1
    fi
}

is_macho_file() {
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

sign_nested_code() {
    local app_path="$1"
    local signed_file_count=0
    local signed_bundle_count=0
    local path

    if [ "${SIGNING_IDENTITY}" = "-" ]; then
        return
    fi

    echo "Signing nested Mach-O runtime and helper code."

    while IFS= read -r -d '' path; do
        if ! is_macho_file "${path}"; then
            continue
        fi

        codesign_path "${path}" 1
        signed_file_count=$((signed_file_count + 1))
        if [ $((signed_file_count % 100)) = "0" ]; then
            echo "  Signed ${signed_file_count} nested Mach-O file(s)..."
        fi
    done < <(find "${app_path}" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) -print0)

    while IFS= read -r path; do
        if [ "${path}" = "${app_path}" ]; then
            continue
        fi

        codesign_path "${path}" 1
        signed_bundle_count=$((signed_bundle_count + 1))
    done < <(find "${app_path}" -depth -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \) -print)

    while IFS= read -r -d '' path; do
        codesign_path "${path}" 1
        signed_file_count=$((signed_file_count + 1))
    done < <(find "${app_path}" -path '*/python/Frameworks/Versions/*/Python' -type f -print0)

    echo "Signed ${signed_file_count} nested Mach-O file(s) and ${signed_bundle_count} nested bundle(s)."
}

resign_app_bundle() {
    local app_path="$1"
    local entitlements_path="$2"
    local codesign_args=(
        codesign
        --force
        --sign "${SIGNING_IDENTITY}"
        --options runtime
    )

    if [ "${SIGNING_IDENTITY}" != "-" ]; then
        codesign_args+=(--timestamp)
    fi

    if [ -s "${entitlements_path}" ]; then
        codesign_args+=(--entitlements "${entitlements_path}")
    fi

    codesign_args+=("${app_path}")
    run "${codesign_args[@]}"
}

submit_for_notarization() {
    local path="$1"
    local result_path="$2"
    local log_path="${result_path%.json}-log.json"
    local status
    local submission_id

    printf '+ xcrun notarytool submit %q --keychain-profile %q --wait --output-format json > %q\n' \
        "${path}" \
        "${NOTARY_PROFILE}" \
        "${result_path}"

    if ! xcrun notarytool submit "${path}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait \
        --output-format json > "${result_path}"; then
        cat "${result_path}" >&2 || true
        exit 1
    fi

    status="$(notary_json_value status "${result_path}")"
    submission_id="$(notary_json_value id "${result_path}")"

    if [ "${status}" != "Accepted" ]; then
        echo "Notarization failed for ${path}. Status: ${status:-unknown}" >&2

        if [ -n "${submission_id}" ]; then
            echo "+ xcrun notarytool log ${submission_id} --keychain-profile ${NOTARY_PROFILE} ${log_path}" >&2
            xcrun notarytool log "${submission_id}" \
                --keychain-profile "${NOTARY_PROFILE}" \
                "${log_path}" >/dev/null || true
            echo "Notarization log: ${log_path}" >&2
        fi

        exit 1
    fi

    echo "Notarization accepted for ${path}."
}

release_exists() {
    local tag="$1"
    gh release view "${tag}" --repo "${REPOSITORY}" >/dev/null 2>&1
}

release_asset_exists() {
    local tag="$1"
    local asset_name="$2"
    gh release view "${tag}" --repo "${REPOSITORY}" --json assets -q '.assets[].name' 2>/dev/null \
        | grep -Fxq "${asset_name}"
}

ensure_release() {
    local tag="$1"
    local title="$2"
    local notes="$3"
    local latest_flag="$4"

    if [ "${SKIP_PUBLISH}" = "1" ]; then
        run_gh_write gh release create "${tag}" --repo "${REPOSITORY}" --title "${title}" --notes "${notes}"
        return
    fi

    if release_exists "${tag}"; then
        if [ "${latest_flag}" = "1" ]; then
            run_gh_write gh release edit "${tag}" \
                --repo "${REPOSITORY}" \
                --title "${title}" \
                --notes "${notes}" \
                --latest
        fi
        return
    fi

    local latest_arg="--latest=false"
    if [ "${latest_flag}" = "1" ]; then
        latest_arg="--latest"
    fi

    run_gh_write gh release create "${tag}" \
        --repo "${REPOSITORY}" \
        --title "${title}" \
        --notes "${notes}" \
        "${latest_arg}"
}

upload_immutable_asset() {
    local tag="$1"
    local path="$2"
    local asset_name
    asset_name="$(basename "${path}")"

    if [ ! -f "${path}" ]; then
        echo "Missing asset: ${path}" >&2
        exit 1
    fi

    if [ "${SKIP_PUBLISH}" = "0" ] && release_asset_exists "${tag}" "${asset_name}"; then
        if [ "${FORCE}" = "0" ]; then
            echo "Asset ${asset_name} already exists on ${tag}." >&2
            echo "App release assets are treated as immutable; pass --force to replace it." >&2
            exit 1
        fi
        run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}" --clobber
    else
        run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}"
    fi
}

upload_moving_asset() {
    local tag="$1"
    local path="$2"

    if [ ! -f "${path}" ]; then
        echo "Missing asset: ${path}" >&2
        exit 1
    fi

    run_gh_write gh release upload "${tag}" "${path}" --repo "${REPOSITORY}" --clobber
}

validate_repo_visibility() {
    if [ "${SKIP_PUBLISH}" = "1" ]; then
        return
    fi

    local visibility
    visibility="$(gh repo view "${REPOSITORY}" --json visibility -q '.visibility')"
    if [ "${visibility}" != "PUBLIC" ]; then
        if [ "${ALLOW_PRIVATE}" = "1" ]; then
            echo "warning: ${REPOSITORY} visibility is ${visibility}; Sparkle downloads will return 404 without authentication." >&2
            return
        fi

        echo "${REPOSITORY} visibility is ${visibility}." >&2
        echo "Sparkle downloads release assets with unauthenticated requests, so app update assets must be public." >&2
        echo "Make the repository public, or rerun with --allow-private for internal publishing tests only." >&2
        exit 1
    fi
}

maybe_download_existing_appcast() {
    local destination="$1"

    if [ "${SKIP_PUBLISH}" = "1" ]; then
        return
    fi

    if release_asset_exists "${APPCAST_TAG}" "appcast.xml"; then
        run gh release download "${APPCAST_TAG}" \
            --repo "${REPOSITORY}" \
            --pattern appcast.xml \
            --dir "${destination}" \
            --clobber
    fi
}

require_command xcodebuild
require_command xcrun
require_command hdiutil
require_command file
require_command shasum
require_command security
require_command /usr/bin/plutil
require_command /usr/bin/ditto
require_command /usr/libexec/PlistBuddy
require_command gh

SPARKLE_DIR="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="${SPARKLE_DIR}/generate_keys"
GENERATE_APPCAST="${SPARKLE_DIR}/generate_appcast"

if [ ! -x "${GENERATE_KEYS}" ] || [ ! -x "${GENERATE_APPCAST}" ]; then
    echo "Sparkle tools were not found. Run: swift package resolve" >&2
    exit 1
fi

if [ -z "${SPARKLE_PUBLIC_KEY}" ]; then
    SPARKLE_PUBLIC_KEY="$("${GENERATE_KEYS}" --account "${SPARKLE_ACCOUNT}" -p)"
fi

if [ -z "${SPARKLE_PUBLIC_KEY}" ] || [[ "${SPARKLE_PUBLIC_KEY}" == *'$('* ]]; then
    echo "Missing concrete Sparkle public key." >&2
    exit 1
fi

if [ "${SKIP_NOTARIZATION}" = "1" ] && [ "${SKIP_PUBLISH}" = "0" ]; then
    echo "--skip-notarization is only allowed together with --skip-publish." >&2
    exit 2
fi

if [ -z "${SIGNING_IDENTITY}" ]; then
    if [ "${SKIP_NOTARIZATION}" = "1" ] && [ "${SKIP_PUBLISH}" = "1" ]; then
        SIGNING_IDENTITY="-"
    else
        SIGNING_IDENTITY="$(detect_signing_identity)"
    fi
fi

if [ -z "${TEAM_ID}" ] && [ "${SIGNING_IDENTITY}" != "-" ]; then
    TEAM_ID="$(infer_team_id_from_identity "${SIGNING_IDENTITY}")"
fi

if [ "${SKIP_NOTARIZATION}" = "0" ]; then
    if [[ "${SIGNING_IDENTITY}" != Developer\ ID\ Application:* ]]; then
        echo "Signing identity must be a Developer ID Application identity for notarized public releases." >&2
        exit 1
    fi

    if [ -z "${TEAM_ID}" ]; then
        echo "Could not infer Apple Developer Team ID from signing identity." >&2
        echo "Pass --team-id or set MLXTRA_DEVELOPMENT_TEAM." >&2
        exit 1
    fi

    if [ "${SETUP_NOTARY}" = "1" ]; then
        store_notary_credentials
    fi

    verify_notary_profile
fi

validate_repo_visibility

MARKETING_VERSION="$(build_setting MARKETING_VERSION)"
BUILD_NUMBER="$(build_setting CURRENT_PROJECT_VERSION)"

if [ -z "${MARKETING_VERSION}" ] || [ -z "${BUILD_NUMBER}" ]; then
    echo "Could not resolve MARKETING_VERSION or CURRENT_PROJECT_VERSION from Xcode build settings." >&2
    exit 1
fi

APP_TAG="app-${MARKETING_VERSION}"
DMG_NAME="MLXtra-${MARKETING_VERSION}.dmg"
ARCHIVE_PATH="${OUTPUT_DIR}/MLXtra.xcarchive"
EXPORT_APP_DIR="${OUTPUT_DIR}/app"
DMG_ROOT="${OUTPUT_DIR}/dmg-root"
APPCAST_SOURCE_DIR="${OUTPUT_DIR}/appcast-source"
ASSETS_DIR="${OUTPUT_DIR}/assets"
NOTARY_ZIP="${OUTPUT_DIR}/MLXtra-${MARKETING_VERSION}-notary.zip"
DMG_PATH="${ASSETS_DIR}/${DMG_NAME}"
APP_PATH="${EXPORT_APP_DIR}/MLXtra.app"
ENTITLEMENTS_PATH="${OUTPUT_DIR}/MLXtra.entitlements.plist"

rm -rf "${ARCHIVE_PATH}" "${EXPORT_APP_DIR}" "${DMG_ROOT}" "${APPCAST_SOURCE_DIR}" "${ASSETS_DIR}" "${NOTARY_ZIP}" "${ENTITLEMENTS_PATH}"
mkdir -p "${OUTPUT_DIR}" "${EXPORT_APP_DIR}" "${DMG_ROOT}" "${APPCAST_SOURCE_DIR}" "${ASSETS_DIR}"

XCODE_ARCHIVE_ARGS=(
    xcodebuild
    archive
    -project "${PROJECT_DIR}/MLXtra.xcodeproj"
    -scheme MLXtra
    -configuration Release
    -destination "generic/platform=macOS"
    -archivePath "${ARCHIVE_PATH}"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}"
    MLXTRA_SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_KEY}"
)

if [ -n "${TEAM_ID}" ]; then
    XCODE_ARCHIVE_ARGS+=(DEVELOPMENT_TEAM="${TEAM_ID}")
fi

if [ "${SIGNING_IDENTITY}" != "-" ]; then
    XCODE_ARCHIVE_ARGS+=(OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

run "${XCODE_ARCHIVE_ARGS[@]}"

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/MLXtra.app"
if [ ! -d "${ARCHIVED_APP}" ]; then
    echo "Archive did not contain ${ARCHIVED_APP}" >&2
    exit 1
fi

run /usr/bin/ditto "${ARCHIVED_APP}" "${APP_PATH}"

ACTUAL_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${APP_PATH}/Contents/Info.plist")"
if [ "${ACTUAL_PUBLIC_KEY}" != "${SPARKLE_PUBLIC_KEY}" ]; then
    echo "Archived app does not contain the expected Sparkle public key." >&2
    exit 1
fi

codesign -d --entitlements :- "${APP_PATH}" > "${ENTITLEMENTS_PATH}" 2>/dev/null || true
prune_broken_symlinks "${APP_PATH}"
prune_packaging_artifacts "${APP_PATH}"
sign_nested_code "${APP_PATH}"
resign_app_bundle "${APP_PATH}" "${ENTITLEMENTS_PATH}"
run codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

if [ "${SKIP_NOTARIZATION}" = "0" ]; then
    run /usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"
    submit_for_notarization "${NOTARY_ZIP}" "${OUTPUT_DIR}/app-notarization-result.json"
    run xcrun stapler staple "${APP_PATH}"
    run xcrun stapler validate "${APP_PATH}"
fi

run /usr/bin/ditto "${APP_PATH}" "${DMG_ROOT}/MLXtra.app"
ln -s /Applications "${DMG_ROOT}/Applications"
run hdiutil create \
    -volname "MLXtra ${MARKETING_VERSION}" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

if [ "${SIGNING_IDENTITY}" != "-" ]; then
    run codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"
    run codesign --verify --verbose=2 "${DMG_PATH}"
fi

if [ "${SKIP_NOTARIZATION}" = "0" ]; then
    submit_for_notarization "${DMG_PATH}" "${OUTPUT_DIR}/dmg-notarization-result.json"
    run xcrun stapler staple "${DMG_PATH}"
    run xcrun stapler validate "${DMG_PATH}"
    run spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"
fi

maybe_download_existing_appcast "${APPCAST_SOURCE_DIR}"
run cp "${DMG_PATH}" "${APPCAST_SOURCE_DIR}/${DMG_NAME}"

RELEASE_NOTES_TARGET="${APPCAST_SOURCE_DIR}/MLXtra-${MARKETING_VERSION}.md"
if [ -n "${RELEASE_NOTES_PATH}" ]; then
    if [ ! -f "${RELEASE_NOTES_PATH}" ]; then
        echo "Release notes file not found: ${RELEASE_NOTES_PATH}" >&2
        exit 1
    fi
    run cp "${RELEASE_NOTES_PATH}" "${RELEASE_NOTES_TARGET}"
else
    {
        echo "# MLXtra ${MARKETING_VERSION}"
        echo
        echo "Build ${BUILD_NUMBER}."
    } > "${RELEASE_NOTES_TARGET}"
fi

DOWNLOAD_URL_PREFIX="https://github.com/${REPOSITORY}/releases/download/${APP_TAG}/"
run "${GENERATE_APPCAST}" \
    --account "${SPARKLE_ACCOUNT}" \
    --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
    "${APPCAST_SOURCE_DIR}"

APPCAST_PATH="${APPCAST_SOURCE_DIR}/appcast.xml"
if [ ! -f "${APPCAST_PATH}" ]; then
    echo "Sparkle did not generate appcast.xml." >&2
    exit 1
fi

DMG_SHA="$(sha256_file "${DMG_PATH}")"
DMG_SIZE="$(file_size "${DMG_PATH}")"

echo ""
echo "Prepared app release:"
echo "  Version: ${MARKETING_VERSION}"
echo "  Build: ${BUILD_NUMBER}"
echo "  DMG: ${DMG_PATH}"
echo "  DMG SHA-256: ${DMG_SHA}"
echo "  DMG size: ${DMG_SIZE} bytes"
echo "  Appcast: ${APPCAST_PATH}"

APP_RELEASE_NOTES="Signed and notarized MLXtra ${MARKETING_VERSION} app release."
if [ "${SKIP_NOTARIZATION}" = "1" ]; then
    APP_RELEASE_NOTES="Signed MLXtra ${MARKETING_VERSION} app release. Notarization was skipped for this local build."
fi

ensure_release \
    "${APP_TAG}" \
    "MLXtra ${MARKETING_VERSION}" \
    "${APP_RELEASE_NOTES}" \
    "1"
upload_immutable_asset "${APP_TAG}" "${DMG_PATH}"

ensure_release \
    "${APPCAST_TAG}" \
    "Appcast Stable" \
    "Moving Sparkle appcast pointer for MLXtra stable app updates." \
    "0"
upload_moving_asset "${APPCAST_TAG}" "${APPCAST_PATH}"
upload_moving_asset "${APPCAST_TAG}" "${RELEASE_NOTES_TARGET}"

echo ""
if [ "${SKIP_PUBLISH}" = "1" ]; then
    echo "Skipped GitHub upload."
else
    echo "Published app release:"
    echo "  https://github.com/${REPOSITORY}/releases/tag/${APP_TAG}"
    echo "Published appcast:"
    echo "  https://github.com/${REPOSITORY}/releases/download/${APPCAST_TAG}/appcast.xml"
fi
