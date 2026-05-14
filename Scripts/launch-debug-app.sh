#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

echo "Building Debug app bundle..."
xcodebuild -project MLXtra.xcodeproj -scheme MLXtra -configuration Debug build

APP_BUNDLE="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/MLXtra.app' -type d -print -quit)"
if [ -z "${APP_BUNDLE}" ]; then
    echo "Could not find built MLXtra.app in DerivedData"
    exit 1
fi

pkill -9 MLXtra 2>/dev/null || true
sleep 1

echo "Launching MLXtra..."
open "${APP_BUNDLE}"

echo "Done!"
