#!/bin/bash
# Xcode "Embed Metadata Engines" build phase.
#
# Copies the vendored engines into the app bundle and signs the native helpers:
#   Contents/Resources/exiftool/   ExifTool (Perl script + library, run by /usr/bin/perl)
#   Contents/Helpers/ffmpeg|ffprobe  LGPL FFmpeg build, signed with the hardened runtime
#                                    and the sandbox "inherit" entitlement
#   Contents/Resources/Licenses/   License texts shown in Help › Third-Party Notices
#
# Missing engines produce a build warning rather than an error so the UI can be
# worked on without them; the app reports missing engines at runtime.
set -euo pipefail

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
VENDOR="${SRCROOT}/Vendor"
HELPER_ENTITLEMENTS="${SRCROOT}/Config/Helper.entitlements"

mkdir -p "$RESOURCES/Licenses"
cp "${SRCROOT}/Config/Licenses/"*.txt "$RESOURCES/Licenses/"

if [[ -f "$VENDOR/exiftool/exiftool" ]]; then
    rsync -a --delete "$VENDOR/exiftool/" "$RESOURCES/exiftool/"
else
    echo "warning: ExifTool is not vendored. Run Scripts/fetch-exiftool.sh"
fi

if [[ -x "$VENDOR/ffmpeg/bin/ffmpeg" && -x "$VENDOR/ffmpeg/bin/ffprobe" ]]; then
    mkdir -p "$HELPERS"
    cp "$VENDOR/ffmpeg/COPYING.LGPLv2.1" "$RESOURCES/Licenses/FFmpeg-LGPL-2.1.txt"
    cp "$VENDOR/ffmpeg/BUILD_INFO.txt" "$RESOURCES/Licenses/FFmpeg-Build-Info.txt"
    cp "$VENDOR/ffmpeg/VERSION" "$RESOURCES/Licenses/FFmpeg-VERSION.txt"

    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi
    TIMESTAMP="--timestamp=none"
    if [[ "${CONFIGURATION}" == "Release" && "$IDENTITY" != "-" ]]; then TIMESTAMP="--timestamp"; fi

    for tool in ffmpeg ffprobe; do
        cp "$VENDOR/ffmpeg/bin/$tool" "$HELPERS/$tool"
        chmod 755 "$HELPERS/$tool"
        if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
            codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP \
                --entitlements "$HELPER_ENTITLEMENTS" "$HELPERS/$tool"
        fi
    done
else
    echo "warning: FFmpeg is not vendored. Run Scripts/build-ffmpeg.sh"
fi
