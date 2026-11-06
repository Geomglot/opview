"""The app's own folders, named after it, and the move from the name it had before (OPRivView Replay)."""
import os
import sys
from pathlib import Path

NAME = "GeoRivViewReplay"
OLD_NAME = "OPRivViewReplay"


def bases() -> list[Path]:
  """the places that hold a folder of the app's: settings, stored drives and logs, as each system has them"""
  home = Path.home()
  if sys.platform == "win32":
    return [Path(os.environ.get("APPDATA") or home / "AppData/Roaming"), Path(os.environ.get("LOCALAPPDATA") or home / "AppData/Local")]
  if sys.platform.startswith("linux"):
    return [Path(os.environ.get(var) or home / default) for var, default in
            (("XDG_CONFIG_HOME", ".config"), ("XDG_CACHE_HOME", ".cache"), ("XDG_STATE_HOME", ".local/state"))]
  return [home / "Library/Application Support", home / "Library/Caches", home / "Library/Logs"]


def folder(base: Path) -> Path:
  """The app's folder in [base]: the old one while it is still there, which is only when moving it failed (a file in
  it held open by a program on Windows, say), so nothing in it is lost from view; the move is tried again next time."""
  old = base / OLD_NAME
  return old if old.is_dir() else base / NAME


def _merge(old: Path, new: Path, left: list[str]) -> None:
  """move what [old] holds into [new]: whole when [new] is not there, else each part that [new] lacks; a file both
  have is the one the app has written since, under the new name, so the old copy goes"""
  try:
    if not new.exists():
      old.rename(new)
      return
    for part in list(old.iterdir()):
      target = new / part.name
      if part.is_dir() and target.is_dir():
        _merge(part, target, left)
      elif target.exists():
        part.unlink()
      else:
        part.rename(target)
    old.rmdir()
  except OSError as e:
    left.append(f"{old}: {e}")


def move_old() -> list[str]:
  """Move each folder of the old name to the new one, with what it holds, so settings and stored drives carry over.
  What cannot be moved now stays, and the app goes on using that folder (see [folder]) until a later start moves it.
  Returns what was left, to be logged."""
  left: list[str] = []
  for base in bases():
    if (base / OLD_NAME).is_dir():
      _merge(base / OLD_NAME, base / NAME, left)
  return left
