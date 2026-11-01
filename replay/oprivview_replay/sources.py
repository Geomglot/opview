"""Where a drive's files come from: the comma itself over SSH, or comma Connect (the cloud) with the JWT in ~/.comma/jwt.

Both put files in the same place, cache/<route>/<segment>/<file name>, so everything after the fetch is the same.
Connect usually has only the small files (qlog and qcamera); the comma has everything it has not yet deleted."""
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from . import ssh_source

API = "https://api.comma.ai"
JWT_FILE = Path.home() / ".comma" / "jwt"
# which Connect file list holds each file
KINDS = {"qlog.zst": "qlogs", "qcamera.ts": "qcameras", "rlog.zst": "logs", "fcamera.hevc": "cameras", "ecamera.hevc": "ecameras"}
_SEGMENT_IN_URL = re.compile(r"/(\d+)/[^/?]+(?:\?|$)")


def _km(miles: float | None) -> float | None:
  """Connect gives a drive's distance in miles, whatever the comma's own km or miles setting is"""
  return None if miles is None else miles * 1.609344


class SourceError(Exception):
  """something the user can act on: no network, no token, a file that was never uploaded"""


class DeviceSource:
  name = "device"

  def __init__(self, host: str):
    self.host = host

  def routes(self) -> dict[str, list[int]]:
    try:
      return ssh_source.list_routes(self.host)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
      raise SourceError(f"cannot reach {self.host}: {e}")

  def is_metric(self) -> bool | None:
    """None when the comma cannot be reached"""
    try:
      return ssh_source.is_metric(self.host)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
      return None

  def missing(self, route: str, segments: list[int], names: tuple[str, ...]) -> list[str]:
    return []  # the comma keeps whole segments; a missing file shows up when it is fetched

  def fetch(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path) -> None:
    try:
      ssh_source.fetch(self.host, route, segments, names, cache)
    except subprocess.CalledProcessError as e:
      raise SourceError(f"could not copy {', '.join(names)} from {self.host}: {e}")


class ConnectSource:
  name = "connect"

  def __init__(self, jwt_file: Path = JWT_FILE):
    self.jwt_file = jwt_file
    self._dongle: str | None = None
    self._files: dict[str, dict] = {}

  def available(self) -> bool:
    return self.jwt_file.exists()

  def _get(self, path: str):
    try:
      token = self.jwt_file.read_text().strip()
    except OSError:
      raise SourceError(f"no comma token at {self.jwt_file}")
    req = urllib.request.Request(API + path, headers={"Authorization": f"JWT {token}"})
    try:
      with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
      hint = " (the token may have expired; get a new one from jwt.comma.ai)" if e.code in (401, 403) else ""
      raise SourceError(f"comma Connect answered {e.code}{hint}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
      raise SourceError(f"cannot reach comma Connect: {getattr(e, 'reason', e)}")

  def dongle(self) -> str:
    if self._dongle is None:
      devices = self._get("/v1/me/devices/")
      mine = [d for d in devices if d.get("is_owner")] or devices
      if not mine:
        raise SourceError("no device on this comma account")
      self._dongle = os.environ.get("COMMA_DONGLE") or mine[0]["dongle_id"]
    return self._dongle

  def device_online(self, within_s: int = 300) -> bool:
    import time
    devices = self._get("/v1/me/devices/")
    ping = next((d.get("last_athena_ping") for d in devices if d["dongle_id"] == self.dongle()), None)
    return bool(ping) and time.time() - ping < within_s

  def listing(self, limit: int = 100) -> dict[str, dict]:
    """route name -> {segments, start_ms, end_ms, lat, lon, km}, newest first"""
    out = {}
    for r in self._get(f"/v1/devices/{self.dongle()}/routes_segments?limit={limit}"):
      name = r["fullname"].split("|", 1)[1]
      out[name] = {"segments": r["segment_numbers"], "start_ms": r["start_time_utc_millis"], "end_ms": r["end_time_utc_millis"],
                   "lat": r.get("start_lat"), "lon": r.get("start_lng"), "km": _km(r.get("distance"))}
    return out

  def routes(self) -> dict[str, list[int]]:
    return {name: info["segments"] for name, info in self.listing().items()}

  def _urls(self, route: str) -> dict[str, dict[int, str]]:
    if route not in self._files:
      files = self._get(f"/v1/route/{self.dongle()}|{route}/files")
      self._files[route] = {kind: {int(m[1]): u for u in urls if (m := _SEGMENT_IN_URL.search(u))} for kind, urls in files.items()
                            if isinstance(urls, list)}
    return self._files[route]

  def missing(self, route: str, segments: list[int], names: tuple[str, ...]) -> list[str]:
    """names that Connect does not have for every one of [segments]"""
    urls = self._urls(route)
    return [n for n in names if any(s not in urls.get(KINDS[n], {}) for s in segments)]

  def fetch(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path) -> None:
    gone = self.missing(route, segments, names)
    if gone:
      raise SourceError(f"comma Connect does not have {', '.join(gone)} for this drive (it was never uploaded)")
    urls = self._urls(route)
    for seg in segments:
      for name in names:
        dest = cache / route / str(seg) / name
        if dest.exists():
          continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + ".part")
        try:
          with urllib.request.urlopen(urls[KINDS[name]][seg], timeout=60) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
              f.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
          part.unlink(missing_ok=True)
          raise SourceError(f"download of {name} for segment {seg} failed: {getattr(e, 'reason', e)}")
        part.rename(dest)
