#!/bin/sh
# Builds Sweep.app from the command line. Usage: Scripts/build-app.sh [Debug|Release]
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build \
  CODE_SIGN_IDENTITY=- 2>&1 \
  | grep -E "error:|warning: |BUILD SUCCEEDED|BUILD FAILED" \
  | grep -vE "appintentsmetadataprocessor|Metadata extraction skipped" \
  | sed -E "s#$(pwd)/##g" | sort -u | cut -c1-400
echo "App: build/DerivedData/Build/Products/$CONFIG/Sweep.app"
