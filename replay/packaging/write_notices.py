#!/usr/bin/env python3
"""Write the licence notices that ship with the app, taken from the packages actually installed for the build.

  python packaging/write_notices.py <destination folder> <ffmpeg work folder>
"""
import importlib.metadata as metadata
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD_ONLY = {"altgraph", "iniconfig", "macholib", "pip", "pluggy", "pygments", "pyinstaller", "pyinstaller-hooks-contrib", "pytest",
              "colorama", "pefile", "pywin32-ctypes"}  # the last three only come with pytest and PyInstaller on Windows
if sys.platform != "win32":
  BUILD_ONLY.add("tzdata")  # installed everywhere for the tests, but only the Windows server carries it (server.spec)
NO_LICENCE_FILE = {"flatbuffers": "Apache License 2.0; the package carries no licence file. See https://github.com/google/flatbuffers"}
HEAD = """OPRivView Replay: licences for the software inside this app

OPRivView Replay
  The app itself. See section "OPRivView Replay" at the end of this file.

FFmpeg 8.1 (ffmpeg and ffprobe)
  https://ffmpeg.org. LGPL version 2.1 or later: see ffmpeg-LICENSE.txt in this folder. The complete source is
  ffmpeg-8.1.tar.xz in this folder. It was built, unchanged, by replay/packaging/build_ffmpeg.sh in
  https://github.com/Geomglot/opview, which lists every option used. You may replace the ffmpeg and ffprobe programs in
  Contents/Resources/ffmpeg with your own build; run "codesign --force --deep -s -" on the app afterwards.

Town names
  From GeoNames (https://www.geonames.org), used under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).
  Reduced to a list of towns by replay/packaging/build_places.py.

Flutter and its packages
  Their licences are in Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z (gzip compressed text).

Python packages and Python itself
  Below. Time zone boundaries come from the timezonefinder-data package, which holds its own licence (ODbL).
  The small program that starts the server is from PyInstaller, under its exception allowing it to ship in any program.
"""
if sys.platform == "win32":  # the same, with where things are in the Windows folder
  HEAD = (HEAD.replace("inside this app", "inside this program")
          .replace("replay/packaging/build_ffmpeg.sh", "replay/packaging/build_ffmpeg_windows.sh")
          .replace("""Contents/Resources/ffmpeg with your own build; run "codesign --force --deep -s -" on the app afterwards.""",
                   "the ffmpeg folder beside OPRivViewReplay.exe with your own build.")
          .replace("Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z", r"data\flutter_assets\NOTICES.Z")
          .replace("Python packages and Python itself\n  Below.", "Python packages and Python itself\n  Below. "
                   "Windows has no time zone database of its own, so the server carries the tzdata package's."))
elif sys.platform.startswith("linux"):  # the same, with where things are in the AppImage
  HEAD = (HEAD.replace("replay/packaging/build_ffmpeg.sh", "replay/packaging/build_ffmpeg_linux.sh")
          .replace("""Contents/Resources/ffmpeg with your own build; run "codesign --force --deep -s -" on the app afterwards.""",
                   "usr/lib/oprivview-replay/ffmpeg with your own build: unpack the AppImage (run it with\n"
                   "  --appimage-extract), replace them, and run AppRun in the unpacked folder. Its NVENC support uses NVIDIA's\n"
                   "  nv-codec-headers (MIT licence, https://github.com/FFmpeg/nv-codec-headers).")
          .replace("Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z",
                   "usr/lib/oprivview-replay/data/flutter_assets/NOTICES.Z inside the AppImage"))


def section(title: str, body: str) -> str:
  return f"\n{'=' * 100}\n{title}\n{'=' * 100}\n\n{body.strip()}\n"


def main(dest: Path, ffmpeg_work: Path) -> None:
  dest.mkdir(parents=True, exist_ok=True)
  parts = [HEAD]
  if sys.platform == "win32":  # a Windows Python keeps its licence at the top of its folder
    python_licence = Path(sys.base_prefix) / "LICENSE.txt"
  else:
    python_licence = Path(sys.base_prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "LICENSE.txt"
  parts.append(section(f"Python {sys.version.split()[0]}", python_licence.read_text(encoding="utf-8", errors="replace")))
  for dist in sorted(metadata.distributions(), key=lambda d: d.metadata["Name"].lower()):
    name = dist.metadata["Name"]
    if name.lower() in BUILD_ONLY:
      continue
    files = [f for f in dist.files or [] if f.suffix not in (".py", ".pyc") and any(word in f.name.upper() for word in ("LICEN", "COPYING", "NOTICE"))]
    if not files and name.lower() not in NO_LICENCE_FILE:
      sys.exit(f"{name} has no licence file; say what its licence is in NO_LICENCE_FILE")
    body = "\n\n".join(f.locate().read_text(encoding="utf-8", errors="replace").strip() for f in files) or NO_LICENCE_FILE[name.lower()]
    parts.append(section(f"{name} {dist.version}", body))
  parts.append(section("OPRivView Replay", (REPO / "LICENSE").read_text(encoding="utf-8")))
  (dest / "THIRD-PARTY-NOTICES.txt").write_text("".join(parts), encoding="utf-8")  # Windows would otherwise use its own code page
  (dest / "ffmpeg-LICENSE.txt").write_bytes((ffmpeg_work / "COPYING.LGPLv2.1").read_bytes())
  shutil.copy2(ffmpeg_work / "ffmpeg-8.1.tar.xz", dest / "ffmpeg-8.1.tar.xz")
  print(f"wrote notices to {dest}")


if __name__ == "__main__":
  main(Path(sys.argv[1]), Path(sys.argv[2]))
