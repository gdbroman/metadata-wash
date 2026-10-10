#!/bin/bash
# Builds a minimal, LGPL-only, dependency-free FFmpeg/FFprobe pair as universal
# (arm64 + x86_64) binaries into Vendor/ffmpeg/bin.
#
# Metadata Wash only remuxes (stream copy), so the build contains no encoders,
# no decoders, no external libraries and no GPL or non-free components. It
# links only against system libraries (libSystem, libz).
#
# Upstream: https://github.com/FFmpeg/FFmpeg  (https://ffmpeg.org)
# License:  LGPL v2.1 or later for this configuration (no --enable-gpl / --enable-nonfree)
set -euo pipefail

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/ffmpeg"
WORK="${FFMPEG_BUILD_DIR:-$(mktemp -d)}"
JOBS="$(sysctl -n hw.ncpu)"

if [[ ! -f "$WORK/ffmpeg.tar.xz" ]]; then
    echo "Downloading FFmpeg $FFMPEG_VERSION…"
    curl -fsSL -o "$WORK/ffmpeg.tar.xz" "$FFMPEG_URL"
fi
echo "$FFMPEG_SHA256  $WORK/ffmpeg.tar.xz" | shasum -a 256 -c -

COMMON_FLAGS=(
    --disable-everything
    --disable-autodetect
    --disable-doc
    --disable-debug
    --disable-network
    --disable-avdevice
    --disable-ffplay
    --enable-static
    --disable-shared
    --enable-zlib
    --enable-protocol=file,pipe
    --enable-demuxer=mov,matroska
    --enable-muxer=mov,mp4,ipod,matroska,webm
    --enable-parser=h264,hevc,vvc,av1,vp8,vp9,mpeg4video,mjpeg,aac,aac_latm,ac3,mpegaudio,opus,vorbis,flac,dca
    --enable-bsf=aac_adtstoasc,vp9_superframe,vp9_superframe_split,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,av1_frame_split,av1_frame_merge,null
)

build_arch() {
    local arch="$1"
    local src="$WORK/src-$arch"
    local prefix="$WORK/out-$arch"
    rm -rf "$src" "$prefix"
    mkdir -p "$src"
    tar -xJf "$WORK/ffmpeg.tar.xz" -C "$src" --strip-components 1

    local extra=()
    if [[ "$arch" != "$(uname -m)" ]]; then
        extra+=(--enable-cross-compile --target-os=darwin)
    fi
    if [[ "$arch" == "x86_64" ]]; then
        # Remux-only build: hand-written x86 assembly gives no benefit and would need nasm.
        extra+=(--disable-x86asm)
    fi

    echo "Configuring FFmpeg for $arch…"
    (
        cd "$src"
        ./configure \
            --prefix="$prefix" \
            --arch="$arch" \
            --cc="xcrun clang -arch $arch" \
            --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
            --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
            "${COMMON_FLAGS[@]}" \
            ${extra[@]+"${extra[@]}"} > "$WORK/configure-$arch.log"
        grep -E "^License:" "$WORK/configure-$arch.log"
        make -j"$JOBS" ffmpeg ffprobe > "$WORK/make-$arch.log" 2>&1
    )
    mkdir -p "$prefix/bin"
    cp "$src/ffmpeg" "$src/ffprobe" "$prefix/bin/"
}

build_arch arm64
build_arch x86_64

rm -rf "$DEST"
mkdir -p "$DEST/bin"
for tool in ffmpeg ffprobe; do
    lipo -create "$WORK/out-arm64/bin/$tool" "$WORK/out-x86_64/bin/$tool" -output "$DEST/bin/$tool"
    strip -x "$DEST/bin/$tool" 2>/dev/null || true
    chmod 755 "$DEST/bin/$tool"
done

echo "$FFMPEG_VERSION" > "$DEST/VERSION"
cp "$WORK/src-arm64/COPYING.LGPLv2.1" "$DEST/COPYING.LGPLv2.1"
{
    echo "FFmpeg $FFMPEG_VERSION"
    echo "Source: $FFMPEG_URL"
    echo "SHA-256: $FFMPEG_SHA256"
    echo "Configure flags: ${COMMON_FLAGS[*]}"
} > "$DEST/BUILD_INFO.txt"

"$DEST/bin/ffmpeg" -hide_banner -L | grep -i "lesser" >/dev/null && echo "License check: LGPL"
lipo -info "$DEST/bin/ffmpeg"
otool -L "$DEST/bin/ffmpeg"
echo "FFmpeg $FFMPEG_VERSION installed in $DEST"
