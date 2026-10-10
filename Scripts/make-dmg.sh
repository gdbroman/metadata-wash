#!/bin/bash
# Builds a Release copy of Metadata Wash and packages it as a drag-to-Applications DMG.
# Output: build/Metadata Wash.dmg
#
# Signing uses the project's automatic signing (Apple Development by default), which
# runs on this Mac. For distribution to other Macs, archive with a Developer ID
# certificate and notarize instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
STAGE="$BUILD/dmg-stage"
DMG="$BUILD/Metadata Wash.dmg"

[[ -f "$ROOT/Vendor/exiftool/exiftool" ]] || "$ROOT/Scripts/fetch-exiftool.sh"
[[ -x "$ROOT/Vendor/ffmpeg/bin/ffmpeg" ]] || "$ROOT/Scripts/build-ffmpeg.sh"

xcodebuild -project "$ROOT/Metadata Wash.xcodeproj" -scheme "Metadata Wash" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD" || true

APP="$DERIVED/Build/Products/Release/Metadata Wash.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Metadata Wash.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Metadata Wash" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
