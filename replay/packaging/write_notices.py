#!/usr/bin/env python3
"""Write the licence notices that ship with the app, taken from the packages actually installed for the build.

  python packaging/write_notices.py <destination folder> <ffmpeg work folder>
"""
import importlib.metadata as metadata
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD_ONLY = {"altgraph", "iniconfig", "macholib", "pip", "pluggy", "pygments", "pyinstaller", "pyinstaller-hooks-contrib", "pytest"}
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


def section(title: str, body: str) -> str:
  return f"\n{'=' * 100}\n{title}\n{'=' * 100}\n\n{body.strip()}\n"


def main(dest: Path, ffmpeg_work: Path) -> None:
  dest.mkdir(parents=True, exist_ok=True)
  parts = [HEAD]
  python_licence = Path(sys.base_prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "LICENSE.txt"
  parts.append(section(f"Python {sys.version.split()[0]}", python_licence.read_text()))
  for dist in sorted(metadata.distributions(), key=lambda d: d.metadata["Name"].lower()):
    name = dist.metadata["Name"]
    if name.lower() in BUILD_ONLY:
      continue
    files = [f for f in dist.files or [] if f.suffix not in (".py", ".pyc") and any(word in f.name.upper() for word in ("LICEN", "COPYING", "NOTICE"))]
    if not files and name.lower() not in NO_LICENCE_FILE:
      sys.exit(f"{name} has no licence file; say what its licence is in NO_LICENCE_FILE")
    body = "\n\n".join(f.locate().read_text(errors="replace").strip() for f in files) or NO_LICENCE_FILE[name.lower()]
    parts.append(section(f"{name} {dist.version}", body))
  parts.append(section("OPRivView Replay", (REPO / "LICENSE").read_text()))
  (dest / "THIRD-PARTY-NOTICES.txt").write_text("".join(parts))
  (dest / "ffmpeg-LICENSE.txt").write_bytes((ffmpeg_work / "COPYING.LGPLv2.1").read_bytes())
  shutil.copy2(ffmpeg_work / "ffmpeg-8.1.tar.xz", dest / "ffmpeg-8.1.tar.xz")
  print(f"wrote notices to {dest}")


if __name__ == "__main__":
  main(Path(sys.argv[1]), Path(sys.argv[2]))
