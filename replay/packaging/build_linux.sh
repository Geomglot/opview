#!/bin/bash
# OPRivView Replay: build the Linux program with its server and ffmpeg beside it, as one AppImage file for release.
# The Linux counterpart of "make dmg" in the Makefile and build_windows.ps1. Run from the replay folder:
#   packaging/build_linux.sh [version] [build number]
# Needs Flutter with its Linux tools (clang cmake ninja-build pkg-config libgtk-3-dev), the replay .venv with
# requirements.txt installed (or PYTHON set to a Python that has them), and an ffmpeg folder from build_ffmpeg_linux.sh
# holding ffmpeg, ffprobe, COPYING.LGPLv2.1 and ffmpeg-8.1.tar.xz (FFMPEG_DIR, default build/ffmpeg-linux). appimagetool
# is downloaded the first time. Build on the oldest Linux the app supports (Ubuntu 22.04): the program needs that
# computer's C library or a later one.
# The version is replay/VERSION with "-dev" on the end, which the app takes as a local build (its updater stays off);
# the release workflow passes the full one, e.g. 0.1.2-test.3, and its run number.
# Leaves build/AppDir and dist/OPRivView-Replay-<version>-Linux-x86_64.AppImage.
set -euo pipefail

replay=$(cd "$(dirname "$0")/.." && pwd)
repo=$(dirname "$replay")
cd "$replay"
base=$(head -n1 VERSION | tr -d '[:space:]')
version=${1:-$base-dev}
build_number=${2:-1}
ffmpeg=${FFMPEG_DIR:-build/ffmpeg-linux}
python=${PYTHON:-$replay/.venv/bin/python}
id=com.geomglot.OPRivViewReplay
appimage="dist/OPRivView-Replay-$version-Linux-x86_64.AppImage"

[[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "replay/VERSION ($base) must be three numbers, such as 0.1.2"; exit 1; }
[[ $version == "$base" || $version =~ ^${base//./\\.}-[0-9A-Za-z.]+$ ]] || { echo "version $version does not start with replay/VERSION ($base)"; exit 1; }
for f in ffmpeg ffprobe COPYING.LGPLv2.1 ffmpeg-8.1.tar.xz; do
  [ -f "$ffmpeg/$f" ] || { echo "$ffmpeg/$f is missing: build ffmpeg first (packaging/build_ffmpeg_linux.sh)"; exit 1; }
done
[ -x "$python" ] || { echo "no $python: create replay/.venv and pip install -r requirements.txt, or set PYTHON"; exit 1; }

echo "== server (PyInstaller)"
"$python" -m PyInstaller packaging/server.spec --distpath dist --workpath build -y --log-level WARN

echo "== app (Flutter)"
(cd "$repo" && flutter build linux --release -t lib/main_replay.dart --build-name="$base" --build-number="$build_number" \
  --dart-define=OPRIVVIEW_REPLAY_VERSION="$version")

# the AppImage holds the app's folder in usr/lib/oprivview-replay; AppRun, the desktop entry and the icon sit at the top,
# where the AppImage tools and desktops look for them
appdir=build/AppDir
app=$appdir/usr/lib/oprivview-replay
echo "== putting it together in $appdir"
rm -rf "$appdir"
mkdir -p "$app/ffmpeg"
cp -a "$repo/build/linux/x64/release/bundle/." "$app/"
cp -a dist/oprivview-replay-server "$app/"
cp "$ffmpeg/ffmpeg" "$ffmpeg/ffprobe" "$app/ffmpeg/"
"$python" packaging/write_notices.py "$app/licenses" "$ffmpeg"
install -m 755 packaging/linux/AppRun "$appdir/AppRun"
install -m 644 "packaging/linux/$id.desktop" "$appdir/$id.desktop"
install -m 644 "$repo/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" "$appdir/$id.png"
ln -s "$id.png" "$appdir/.DirIcon"

# the app finds its server and ffmpeg beside itself (lib/studio/sidecar.dart); check they are where it looks
for f in oprivview-replay oprivview-replay-server/oprivview-replay-server ffmpeg/ffmpeg ffmpeg/ffprobe lib/libapp.so \
         licenses/THIRD-PARTY-NOTICES.txt; do
  [ -e "$app/$f" ] || { echo "$app/$f is missing"; exit 1; }
done

tool=build/appimagetool-x86_64.AppImage
if [ ! -x "$tool" ]; then
  echo "== appimagetool"
  curl -sSfL --retry 3 -o "$tool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$tool"
fi
echo "appimagetool $(sha256sum "$tool" | cut -d' ' -f1)"
mkdir -p dist
rm -f "$appimage"
# run unpacked, so building needs no FUSE; the AppImage it makes uses the static runtime, which needs no libfuse2 either
ARCH=x86_64 VERSION="$version" "$tool" --appimage-extract-and-run --no-appstream "$appdir" "$appimage"
echo "AppImage: $replay/$appimage ($(( $(stat -c %s "$appimage") / 1048576 )) MB)"
echo "SHA-256 $(sha256sum "$appimage" | cut -d' ' -f1)"
