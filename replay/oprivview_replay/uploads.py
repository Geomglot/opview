"""What the app has asked the comma to upload to comma Connect, so the drive pane can say so even while the comma is
offline and cannot be asked about its queue. Kept in one small file beside the stored drives."""
import json
import os
import threading
import time
from pathlib import Path

# a request the comma has not acted on in this long is assumed lost (the relay keeps one for 7 days), and asked again
STALE_S = 7 * 86400


class UploadRequests:
  def __init__(self, path: Path):
    self.path = path
    self._lock = threading.Lock()

  def _load(self) -> dict:
    try:
      return json.loads(self.path.read_text())
    except (OSError, ValueError):
      return {}

  def _save(self, data: dict) -> None:
    self.path.parent.mkdir(parents=True, exist_ok=True)
    tmp = self.path.with_name(self.path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.replace(tmp, self.path)

  def get(self, route: str) -> dict | None:
    """{"at": Unix time, "files": [[segment, name], ...], "offline": bool} for the last request for [route]"""
    with self._lock:
      return self._load().get(route)

  def add(self, route: str, files: list[tuple[int, str]], offline: bool, now: float | None = None) -> None:
    """remember a request; files already asked for and not yet stale are kept with it"""
    now = time.time() if now is None else now
    with self._lock:
      data = self._load()
      old = data.get(route)
      kept = [tuple(f) for f in old["files"]] if old and now - old["at"] < STALE_S else []
      data[route] = {"at": now, "files": sorted(set(kept) | set(files)), "offline": offline}
      self._save(data)

  def asked_recently(self, route: str, files: list[tuple[int, str]], now: float | None = None) -> bool:
    """every one of [files] was asked for in the last 7 days, so asking again would only repeat it"""
    now = time.time() if now is None else now
    old = self.get(route)
    return bool(old) and now - old["at"] < STALE_S and set(files) <= {tuple(f) for f in old["files"]}

  def drop(self, route: str) -> None:
    with self._lock:
      data = self._load()
      if data.pop(route, None) is not None:
        self._save(data)
