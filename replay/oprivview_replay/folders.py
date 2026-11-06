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


def move_old() -> list[str]:
  """Rename each folder of the old name to the new one, where there is no new one yet, so settings and stored drives
  carry over; one that cannot be moved (another drive, say) is left as it is and the app starts that part afresh.
  Returns what was not moved, to be logged."""
  left = []
  for base in bases():
    old, new = base / OLD_NAME, base / NAME
    if old.is_dir() and not new.exists():
      try:
        old.rename(new)
      except OSError as e:
        left.append(f"{old}: {e}")
  return left
