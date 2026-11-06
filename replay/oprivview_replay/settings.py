"""What the user chose in the app's settings; kept in one small file."""
import json
import os
from pathlib import Path

from . import folders


def default_file() -> Path:
  """the settings file, in the app's folder in the system's place for settings (its first in [folders.bases])"""
  return folders.folder(folders.bases()[0]) / "settings.json"


DEFAULT_FILE = default_file()
DEFAULTS: dict = {
  "host": "comma",  # how to reach the comma over SSH: a name from ~/.ssh/config or an address
  "dongle": None,  # which device on the comma account; None means the first one the account owns
  "output_dir": None,  # None means the Movies folder (Videos on Windows and Linux)
  "added": [],  # public drives and devices of other people: "dongle|route" or "dongle"
  "test_versions": True,  # whether the app's updater offers test versions (pre-releases) as well as final ones
  "keep_on_connect": True,  # when the full files come from the comma away from this network, or cannot, ask it to put them on Connect
  "via_server": True,  # fetch through comma's SSH server (comma prime) when the comma is not on this network
  # ask before fetching this many segments or more that are not on this computer yet (0: never ask), from the comma on
  # this network, which copies quickly, and from comma Connect or through comma's server
  "ask_segments_home": 30,
  "ask_segments_away": 5,
}


class Settings:
  def __init__(self, path: Path = DEFAULT_FILE):
    self.path = path
    self.values = dict(DEFAULTS)
    try:
      self.values.update(json.loads(path.read_text()))
    except (OSError, ValueError):
      pass  # none saved yet, or unreadable: the defaults still work

  def __getitem__(self, key: str):
    return self.values[key]

  def update(self, **changes) -> None:
    unknown = set(changes) - set(DEFAULTS)
    if unknown:
      raise ValueError(f"unknown setting: {', '.join(sorted(unknown))}")
    self.values.update(changes)
    self.path.parent.mkdir(parents=True, exist_ok=True)
    tmp = self.path.with_name(self.path.name + ".tmp")
    tmp.write_text(json.dumps(self.values, indent=1))
    os.replace(tmp, self.path)
