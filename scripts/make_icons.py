#!/usr/bin/env python3
"""Makes every app icon from docs/georivview_icon.svg, so the phone app and Replay on each computer show the same picture.

  python scripts/make_icons.py

Needs Google Chrome, which draws the SVG (set CHROME to its path if it is somewhere unusual), and Pillow. The PNGs and the
Windows .ico it writes are committed; nothing in a build runs this.

  Android, before 8:  the whole design cut to a circle            mipmap-*/ic_launcher.png
  Android 8 and later: the design on its own, a launcher puts it on black and crops it as it likes
                                                                  mipmap-*/ic_launcher_foreground.png
  Mac, Windows, Linux: the design shrunk onto a rounded black tile, as desktop icons are
                                                                  macos/.../AppIcon.appiconset, windows/.../app_icon.ico
                                                                  (Linux's AppImage takes the Mac's 256 pixel one)
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "docs" / "georivview_icon.svg"
MASTER = 1024  # drawn this big, then made smaller, so the small sizes stay sharp

ANDROID = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
MAC = [16, 32, 64, 128, 256, 512, 1024]
WINDOWS = [16, 24, 32, 48, 64, 128, 256]

# an adaptive icon's foreground is 108dp, of which a launcher shows about the middle 72; this many design units fit across
# it so the ring sits where the old foreground had it, inside the part every launcher shows
FOREGROUND_UNITS = 661.5


def chrome() -> str:
  candidates = [os.environ.get("CHROME"),
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                shutil.which("google-chrome"), shutil.which("chromium"), shutil.which("chromium-browser")]
  for c in candidates:
    if c and Path(c).exists():
      return c
  sys.exit("Google Chrome was not found; set CHROME to its path")


def draw(svg: str, work: Path, name: str) -> Image.Image:
  """the SVG as a MASTER-pixel square with a see-through background"""
  page = work / f"{name}.html"
  page.write_text("<!doctype html><style>html,body{margin:0;background:transparent}</style>" + svg, encoding="utf-8")
  out = work / f"{name}.png"
  subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
                  f"--window-size={MASTER},{MASTER}", f"--screenshot={out}", page.as_uri()],
                 check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  return Image.open(out).convert("RGBA")


def save(master: Image.Image, size: int, path: Path) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  master.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def main() -> None:
  source = SOURCE.read_text(encoding="utf-8")
  inner = re.sub(r"^\s*<svg[^>]*>|</svg>\s*$", "", source)
  background = '<rect width="512" height="512" fill="#000"/>'
  assert background in inner, "the design's black square has changed; update make_icons.py"
  design = inner.replace(background, "", 1)

  def svg(view_box: str, body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{MASTER}" height="{MASTER}" viewBox="{view_box}">'
            f'{body}</svg>')

  edge = 256 - FOREGROUND_UNITS / 2
  with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    legacy = draw(svg("0 0 512 512", '<clipPath id="round"><circle cx="256" cy="256" r="256"/></clipPath>'
                      f'<g clip-path="url(#round)">{inner}</g>'), work, "legacy")
    foreground = draw(svg(f"{edge} {edge} {FOREGROUND_UNITS} {FOREGROUND_UNITS}", design), work, "foreground")
    tile = draw(svg("0 0 512 512", '<clipPath id="tile"><rect x="50" y="50" width="412" height="412" rx="92"/></clipPath>'
                    '<g clip-path="url(#tile)"><rect width="512" height="512" fill="#000"/>'
                    f'<g transform="translate(256,256) scale(.8) translate(-256,-256)">{design}</g></g>'), work, "tile")

  res = REPO / "android" / "app" / "src" / "main" / "res"
  for density, scale in ANDROID.items():
    save(legacy, round(48 * scale), res / f"mipmap-{density}" / "ic_launcher.png")
    save(foreground, round(108 * scale), res / f"mipmap-{density}" / "ic_launcher_foreground.png")
  mac = REPO / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
  for size in MAC:
    save(tile, size, mac / f"app_icon_{size}.png")
  tile.save(REPO / "windows" / "runner" / "resources" / "app_icon.ico", sizes=[(s, s) for s in WINDOWS])
  print("icons written")


if __name__ == "__main__":
  main()
