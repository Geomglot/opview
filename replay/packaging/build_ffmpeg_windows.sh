#!/bin/bash
# Builds the ffmpeg.exe and ffprobe.exe the Windows program ships with, from the official source, holding only what the
# app uses: the Windows counterpart of build_ffmpeg.sh, with the same choices. The result is LGPL (no x264 or other GPL
# parts) and needs no DLLs beyond Windows' own. Encoding goes through the graphics card's encoder when there is one
# (NVIDIA NVENC, AMD AMF: their header files only, the driver supplies the code at run time), else Windows' own Media
# Foundation encoder.
#
#   packaging/build_ffmpeg_windows.sh <work folder>
# Run in an MSYS2 MINGW64 shell with: pacman -S make diffutils pkgconf tar xz mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm
#   mingw-w64-x86_64-ffnvcodec-headers mingw-w64-x86_64-amf-headers
# Leaves <work folder>/ffmpeg.exe, ffprobe.exe, the source archive and the licence: the folder build_windows.ps1 takes.
set -euo pipefail

VERSION=8.1
SHA256=b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a

work=$(mkdir -p "$1" && cd "$1" && pwd)
archive="$work/ffmpeg-$VERSION.tar.xz"
cd "$work"
# ffmpeg.org is sometimes slow to answer, so try a few times; the checksum below still decides what is used
[ -f "$archive" ] || curl -sSfL --connect-timeout 30 --retry 5 --retry-all-errors --retry-delay 20 \n  -o "$archive" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
echo "$SHA256  $archive" | sha256sum -c -
rm -rf "ffmpeg-$VERSION"
tar xf "$archive"
cd "ffmpeg-$VERSION"

# the same components as the Mac's build, with Windows' encoders in place of VideoToolbox; -static keeps the MinGW
# runtime inside the programs, so they need nothing installed beside them
./configure --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay \
  --disable-shared --enable-static --extra-ldflags=-static \
  --enable-mediafoundation --enable-d3d11va --enable-ffnvcodec --enable-nvenc --enable-amf \
  --enable-protocol=file,pipe,fd,concat \
  --enable-demuxer=hevc,h264,mpegts,mov,rawvideo \
  --enable-parser=hevc,h264 \
  --enable-decoder=hevc,h264,rawvideo \
  --enable-hwaccel=hevc_d3d11va,h264_d3d11va \
  --enable-filter=trim,setpts,scale,format,null \
  --enable-encoder=h264_mf,h264_nvenc,h264_amf,rawvideo \
  --enable-muxer=mp4,rawvideo | tee configure.out
grep -q "^License: LGPL version 2.1 or later" configure.out || { echo "configure did not choose LGPL 2.1 or later"; exit 1; }
make -j"$(nproc)"
cp ffmpeg.exe ffprobe.exe COPYING.LGPLv2.1 "$work/"
cd "$work"
rm -rf "ffmpeg-$VERSION"
