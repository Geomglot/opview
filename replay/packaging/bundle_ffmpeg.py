#!/usr/bin/env python3
"""Copy ffmpeg and ffprobe, and every non-system library they need, into one folder, with the library paths
rewritten to sit beside the programs. The folder runs on a Mac that has no ffmpeg installed.

  python packaging/bundle_ffmpeg.py <destination folder>
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM = ("/usr/lib/", "/System/Library/")
TOOLS = ("ffmpeg", "ffprobe")


def find(name: str) -> Path:
  found = shutil.which(name) or next((c for c in (f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}") if os.path.isfile(c)), None)
  if not found:
    sys.exit(f"{name} not found; install it with: brew install ffmpeg")
  return Path(found).resolve()


def deps(binary: Path) -> list[str]:
  out = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
  refs = [line.split()[0] for line in out if line.strip()]
  return [r for r in refs if not r.startswith(SYSTEM) and Path(r).name != binary.name]


def locate(ref: str, origin: Path) -> Path:
  if ref.startswith("@rpath/"):
    for lib in (origin.parent.parent / "lib", Path("/usr/local/lib"), Path("/opt/homebrew/lib")):
      if (lib / ref[7:]).exists():
        return (lib / ref[7:]).resolve()
    sys.exit(f"cannot find {ref} needed by {origin}")
  return Path(ref).resolve()


def change(binary: Path, old: str, new: str) -> None:
  subprocess.run(["install_name_tool", "-change", old, new, str(binary)], check=True, capture_output=True)


def main(dest: Path) -> None:
  if dest.exists():
    shutil.rmtree(dest)
  dest.mkdir(parents=True)
  origins: dict[Path, Path] = {}  # copy -> where it came from
  for tool in TOOLS:
    src = find(tool)
    shutil.copy2(src, dest / tool)
    origins[dest / tool] = src
  queue = list(origins)
  done: dict[Path, Path] = {}  # real source -> copy
  while queue:
    binary = queue.pop()
    for ref in deps(binary):
      src = locate(ref, origins[binary])
      if src not in done:
        copy = dest / src.name
        shutil.copy2(src, copy)
        os.chmod(copy, 0o755)
        subprocess.run(["install_name_tool", "-id", f"@loader_path/{src.name}", str(copy)], check=True, capture_output=True)
        done[src] = copy
        origins[copy] = src
        queue.append(copy)
      change(binary, ref, f"@loader_path/{src.name}")
  for f in sorted(dest.iterdir()):
    left = deps(f)
    if any(not r.startswith("@loader_path") for r in left):
      sys.exit(f"{f.name} still points outside the folder: {left}")
  print(f"bundled {', '.join(TOOLS)} and {len(done)} libraries into {dest}")


if __name__ == "__main__":
  main(Path(sys.argv[1]))
