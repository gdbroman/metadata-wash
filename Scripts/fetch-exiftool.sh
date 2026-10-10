#!/bin/bash
# Fetches a pinned ExifTool distribution into Vendor/exiftool.
#
# ExifTool is pure Perl and runs on the /usr/bin/perl that ships with macOS,
# so nothing has to be installed on the user's Mac. Only the `exiftool` script
# and its `lib/` tree are kept; docs, tests and translations are dropped.
#
# Upstream: https://github.com/exiftool/exiftool (Phil Harvey)
# License:  same terms as Perl itself (Artistic License or GPL v1+)
set -euo pipefail

EXIFTOOL_VERSION="13.59"
EXIFTOOL_SHA256="87d3317882fdae9cb4dcfe57a96a378d0132ffc02c731315bf128b19ddcf7aac"
EXIFTOOL_URL="https://github.com/exiftool/exiftool/archive/refs/tags/${EXIFTOOL_VERSION}.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/exiftool"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ExifTool $EXIFTOOL_VERSION…"
curl -fsSL -o "$WORK/exiftool.tar.gz" "$EXIFTOOL_URL"
echo "$EXIFTOOL_SHA256  $WORK/exiftool.tar.gz" | shasum -a 256 -c -

mkdir -p "$WORK/src"
tar -xzf "$WORK/exiftool.tar.gz" -C "$WORK/src" --strip-components 1

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$WORK/src/exiftool" "$DEST/exiftool"
cp -R "$WORK/src/lib" "$DEST/lib"
cp "$WORK/src/README" "$DEST/README"
# Translations are only used with -lang; they add several MB.
rm -rf "$DEST/lib/Image/ExifTool/Lang"
chmod 755 "$DEST/exiftool"
echo "$EXIFTOOL_VERSION" > "$DEST/VERSION"

echo "ExifTool $EXIFTOOL_VERSION installed in $DEST"
