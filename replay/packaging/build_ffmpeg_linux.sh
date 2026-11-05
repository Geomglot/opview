#!/bin/bash
# Builds the ffmpeg and ffprobe the Linux program ships with, from the official source, holding only what the app uses:
# the Linux counterpart of build_ffmpeg.sh, with the same choices. The result is LGPL (no x264 or other GPL parts).
# Encoding goes through the graphics card's encoder: NVIDIA's NVENC (header files only, the driver supplies the code at
# run time) or Intel's and AMD's through VA-API, which uses the computer's own libva. A computer with neither encodes
# with its own full ffmpeg instead, if it has one (render.py chooses).
#
#   packaging/build_ffmpeg_linux.sh <work folder>
# Needs a C compiler, make, nasm, pkg-config, curl, git and libva's headers (Ubuntu: build-essential nasm pkg-config
# libva-dev). Build on the oldest Linux the app supports, as the programs need its C library or a later one.
# Leaves <work folder>/ffmpeg, ffprobe, the source archive and the licence.
set -euo pipefail

# ffmpeg's version, set here and never taken from the environment: make passes the app's own VERSION (0.1.2-test.1)
# down to this script
VERSION=8.1
SHA256=b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a
# NVIDIA's header files for NVENC (MIT licence): an older release, so drivers from 520 on can run it
NVCODEC=n12.0.16.1

work=$(mkdir -p "$1" && cd "$1" && pwd)
archive="$work/ffmpeg-$VERSION.tar.xz"
cd "$work"
# the source from ffmpeg.org, or else our copy of the same file (GitHub's build machines sometimes cannot reach
# ffmpeg.org); either way the checksum below decides what is used
fetch() { curl -sSfL --connect-timeout 30 --retry "$1" --retry-all-errors --retry-delay 10 -o "$archive" "$2"; }
[ -f "$archive" ] || fetch 1 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" ||
  fetch 3 "https://github.com/Geomglot/opview/releases/download/ffmpeg-$VERSION-source/ffmpeg-$VERSION.tar.xz"
echo "$SHA256  $archive" | sha256sum -c -
rm -rf "ffmpeg-$VERSION" nv-codec-headers headers
tar xf "$archive"

git -c advice.detachedHead=false clone -q --depth 1 --branch "$NVCODEC" https://github.com/FFmpeg/nv-codec-headers.git
make -C nv-codec-headers install PREFIX="$work/headers" >/dev/null
export PKG_CONFIG_PATH="$work/headers/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cd "ffmpeg-$VERSION"
# the same components as the Mac's build, with Linux's encoders in place of VideoToolbox; ffmpeg's own code is linked
# in, so the programs need only the C library and libva, which every desktop Linux has
./configure --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay \
  --disable-shared --enable-static \
  --enable-vaapi --enable-ffnvcodec --enable-nvenc \
  --enable-protocol=file,pipe,fd,concat \
  --enable-demuxer=hevc,h264,mpegts,mov,rawvideo \
  --enable-parser=hevc,h264 \
  --enable-decoder=hevc,h264,rawvideo \
  --enable-filter=trim,setpts,scale,format,null,hwupload \
  --enable-encoder=h264_nvenc,h264_vaapi,rawvideo \
  --enable-muxer=mp4,rawvideo | tee configure.out
grep -q "^License: LGPL version 2.1 or later" configure.out || { echo "configure did not choose LGPL 2.1 or later"; exit 1; }
for wanted in h264_nvenc h264_vaapi; do
  grep -A20 "^Enabled encoders:" configure.out | grep -qw "$wanted" || { echo "configure left out $wanted"; exit 1; }
done
make -j"$(nproc)"
strip ffmpeg ffprobe
cp ffmpeg ffprobe COPYING.LGPLv2.1 "$work/"
cd "$work"
rm -rf "ffmpeg-$VERSION" nv-codec-headers headers
