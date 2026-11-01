#!/bin/bash
# Builds the ffmpeg and ffprobe the app ships with, from the official source, holding only what the app uses.
# The result is LGPL (no x264 or other GPL parts), needs no other libraries, and runs on older versions of macOS than
# the Homebrew build does. Encoding goes through Apple's own VideoToolbox.
#
#   packaging/build_ffmpeg.sh <work folder>
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

./configure --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay \
  --disable-shared --enable-static --enable-videotoolbox \
  --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
  --enable-protocol=file,pipe,fd,concat \
  --enable-demuxer=hevc,h264,mpegts,mov,rawvideo \
  --enable-parser=hevc,h264 \
  --enable-decoder=hevc,h264,rawvideo \
  --enable-hwaccel=hevc_videotoolbox,h264_videotoolbox \
  --enable-filter=trim,setpts,scale,format,null \
  --enable-encoder=h264_videotoolbox,rawvideo \
  --enable-muxer=mp4,rawvideo
make -j"$(sysctl -n hw.ncpu)"
cp ffmpeg ffprobe COPYING.LGPLv2.1 "$work/"
cd "$work"
rm -rf "ffmpeg-$VERSION"
