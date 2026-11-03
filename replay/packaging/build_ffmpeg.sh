#!/bin/bash
# Builds the ffmpeg and ffprobe the app ships with, from the official source, holding only what the app uses.
# The result is LGPL (no x264 or other GPL parts), needs no other libraries, and runs on older versions of macOS than
# the Homebrew build does. Encoding goes through Apple's own VideoToolbox.
#
#   packaging/build_ffmpeg.sh <work folder> [arch]
#   arch is arm64 or x86_64; it defaults to the Mac doing the build, so running this on Apple silicon makes an
#   arm64 ffmpeg and on an Intel Mac an x86_64 one. Building the other arch on this Mac crosses over automatically.
# Needs nasm (brew install nasm). Leaves <work folder>/ffmpeg, ffprobe, the source archive and the licence.
set -euo pipefail

VERSION=8.1
SHA256=b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a
MIN_MACOS=12.0

work=$(mkdir -p "$1" && cd "$1" && pwd)
archive="$work/ffmpeg-$VERSION.tar.xz"
cd "$work"
[ -f "$archive" ] || curl -sSfL -o "$archive" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
echo "$SHA256  $archive" | shasum -a 256 -c -
rm -rf "ffmpeg-$VERSION"
tar xf "$archive"
cd "ffmpeg-$VERSION"

arch=${2:-$(uname -m)}
if [ "$arch" = "$(uname -m)" ]; then
  # native build: use this Mac's own assembler and cc
  cross=("--arch=$arch")
  cflags=(-mmacosx-version-min=$MIN_MACOS)
  ldflags=(-mmacosx-version-min=$MIN_MACOS)
else
  # the other arch: clang on macOS crosses with -arch, from the same SDK. nasm is left on: it
  # always assembles x86 objects, so an x86_64 build uses it for its SIMD even on Apple silicon.
  cross=("--arch=$arch" --enable-cross-compile --cc=clang)
  cflags=(-arch "$arch" -mmacosx-version-min=$MIN_MACOS)
  ldflags=(-arch "$arch" -mmacosx-version-min=$MIN_MACOS)
fi

./configure "${cross[@]}" --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug \
  --disable-ffplay \
  --disable-shared --enable-static --enable-videotoolbox \
  --extra-cflags="${cflags[*]}" --extra-ldflags="${ldflags[*]}" \
  --enable-protocol=file,pipe,fd,concat \
  --enable-demuxer=hevc,h264,mpegts,mov,rawvideo \
  --enable-parser=hevc,h264 \
  --enable-decoder=hevc,h264,rawvideo \
  --enable-hwaccel=hevc_videotoolbox,h264_videotoolbox \
  --enable-filter=trim,setpts,scale,format,null \
  --enable-encoder=h264_videotoolbox,rawvideo \
  --enable-muxer=mp4,rawvideo
# ffmpeg's make has its own ARCH (aarch64, x86_64, ...) per-arch source folders. Our caller's
# command-line variables travel in MAKEFLAGS, so an outer `make dmg ARCH=ARM` would override
# ffmpeg's and pull in the 32-bit arm/ folders; drop the caller's make settings here.
env -u MAKEFLAGS -u MAKELEVEL make -j"$(sysctl -n hw.ncpu)"
cp ffmpeg ffprobe COPYING.LGPLv2.1 "$work/"
cd "$work"
rm -rf "ffmpeg-$VERSION"
