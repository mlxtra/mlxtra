#!/bin/bash
# MLXHub Launch Script

cd /Users/omercelik/Documents/codex/kimistudio/MLXHub

# Build release version
echo "Building release version..."
swift build -c release

# Copy to app bundle
echo "Copying to app bundle..."
cp .build/release/MLXHub MLXHub.app/Contents/MacOS/MLXHub

# Kill existing instance
pkill -9 MLXHub 2>/dev/null || true
sleep 1

# Launch app
echo "Launching MLXHub..."
open MLXHub.app

echo "Done!"
