"""Where a drive's files come from: the comma itself over SSH, or comma Connect (the cloud) with the JWT in ~/.comma/jwt.

Both put files in the same place, cache/<route>/<segment>/<file name>, so everything after the fetch is the same.
Connect usually has only the small files (qlog and qcamera); the comma has everything it has not yet deleted."""
import json
import os
import re
from datetime import datetime, timezone
import ssl
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

import certifi

from . import ssh_source

API = "https://api.comma.ai"
# the computer's own trust store, plus certifi's list whatever Python built the app; a missing default path is ignored
TLS = ssl.create_default_context()
TLS.load_verify_locations(certifi.where())
JWT_FILE = Path.home() / ".comma" / "jwt"
# which Connect file list holds each file
KINDS = {"qlog.zst": "qlogs", "qcamera.ts": "qcameras", "rlog.zst": "logs", "fcamera.hevc": "cameras", "ecamera.hevc": "ecameras"}
_SEGMENT_IN_URL = re.compile(r"/(\d+)/[^/?]+(?:\?|$)")
_DONGLE = re.compile(r"\b[0-9a-f]{16}\b")
_ROUTE = re.compile(r"\b[0-9a-f]{8}--[0-9a-f]{10}\b")


def _km(miles: float | None) -> float | None:
  """Connect gives a drive's distance in miles, whatever the comma's own km or miles setting is"""
  return None if miles is None else miles * 1.609344


FULL_FILES = ("rlog.zst", "fcamera.hevc")
LOGS_FILES = ("rlog.zst", "qcamera.ts")
QUICK_FILES = ("qlog.zst", "qcamera.ts")


class SourceError(Exception):
  """something the user can act on: no network, no token, a file that was never uploaded"""


def parse_drive_ref(text: str) -> tuple[str, str | None]:
  """(device, route or None) from a Connect link, or "device/route", "device|route" or a device id on its own"""
  dongle, route = _DONGLE.search(text), _ROUTE.search(text)
  if dongle is None:
    raise SourceError("that does not contain a comma device id, which is 16 letters and digits")
  return dongle[0], route[0] if route else None


class DeviceSource:
  """the comma on this network, or with a [ssh_source.ThroughServer] host, the comma through comma's own SSH server"""

  def __init__(self, host: "ssh_source.Host"):
    self.host = host  # changes when the user picks another address in the settings
    self.through_server = isinstance(host, ssh_source.ThroughServer)
    self.name = "the comma through comma's server" if self.through_server else "device"

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
    """On this network the comma keeps whole segments, and a missing file shows up when it is fetched. Through comma's
    server it is only chosen when Connect lacks the files, so it is asked, in one command, rather than assumed to have
    them: a drive it has already deleted then falls back to what Connect has."""
    if not self.through_server:
      return []
    try:
      sizes = ssh_source.remote_sizes(self.host, [f"{route}--{s}/{n}" for s in segments for n in names])
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
      raise SourceError(f"cannot reach the comma through comma's server: {e}")
    return [n for n in names if any(f"{route}--{s}/{n}" not in sizes for s in segments)]

  def fetch(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path,
            progress: Callable[[str], None] | None = None) -> None:
    """[progress] is told, about once a second, how much of a copy through comma's server has arrived"""
    if not self.through_server:
      try:
        ssh_source.fetch(self.host, route, segments, names, cache)
      except subprocess.CalledProcessError as e:
        raise SourceError(f"could not copy {', '.join(names)} from {self.host}: {e}")
      return
    try:
      sizes = ssh_source.remote_sizes(self.host, [f"{route}--{s}/{n}" for s in segments for n in names])
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
      sizes = {}
    tick = self._counter(route, segments, names, cache, progress, sizes) if progress is not None else None
    try:
      ssh_source.fetch(self.host, route, segments, names, cache, tick)
    except BaseException as e:
      # a copy stopped part-way (Cancel, or the comma dropping off) keeps what came, under the file's own name, for the
      # next copy from the comma to finish. Mark those files, so that a download from Connect does not take them as whole.
      for s in segments:
        for n in names:
          f = cache / route / str(s) / n
          if f.exists() and f.stat().st_size != sizes.get(f"{route}--{s}/{n}"):
            incomplete_marker(f).touch()
      if isinstance(e, subprocess.CalledProcessError):
        raise SourceError(f"could not copy {', '.join(names)} from the comma through comma's server: {e}")
      raise
    for s in segments:
      for n in names:
        incomplete_marker(cache / route / str(s) / n).unlink(missing_ok=True)

  def _counter(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path,
               progress: Callable[[str], None], sizes: dict[str, int]) -> Callable[[], None]:
    """How much of each file is here, out of its size on the comma. A file can be in three places while it comes: under
    its own name (whole, or kept from a copy stopped part-way), as rsync's hidden .<name>.<random> beside it, or in
    scp's .part folder. The largest of them counts, so a resumed copy starts at what is already here and the count
    never goes backwards when rsync's new copy replaces the old part."""

    def arrived(s: int, n: str, size: int) -> int:
      folder = cache / route / str(s)
      places = [folder / n, folder / ".part" / n, *(folder.glob(f".{n}.*") if folder.exists() else ())]
      return min(size, max((_size(p) for p in places), default=0))

    wanted = [(s, n, size) for s in segments for n in names if (size := sizes.get(f"{route}--{s}/{n}")) is not None]
    total = sum(size for _, _, size in wanted)

    def tick() -> None:
      done = sum(arrived(s, n, size) for s, n, size in wanted)
      progress(f"fetching {', '.join(names)} from the comma through comma's server: {done / 1e6:.0f} of {total / 1e6:.0f} MB")
    return tick


def _size(path: Path) -> int:
  try:
    return path.stat().st_size
  except OSError:  # not there, or renamed away by the copy just now
    return 0


def incomplete_marker(file: Path) -> Path:
  """beside a file a copy from the comma left part-way; while it is there the file is not to be used as it is"""
  return file.with_name(file.name + ".incomplete")


class ConnectSource:
  """the user's own device with their token, or with [public] someone else's device, for what its owner has made public"""
  name = "connect"

  def __init__(self, jwt_file: Path = JWT_FILE, dongle: str | None = None, public: bool = False):
    self.jwt_file = jwt_file
    self.public = public
    self._dongle = dongle
    self._files: dict[str, dict] = {}
    self._infos: dict[str, dict] = {}

  def available(self) -> bool:
    return self.public or self.jwt_file.exists()

  def forget(self) -> None:
    """a new token or device: what was looked up with the old one no longer applies"""
    self._files.clear()
    self._infos.clear()

  def use_device(self, dongle: str | None) -> None:
    self._dongle = dongle
    self.forget()

  def check_token(self, token: str) -> None:
    """raises SourceError unless comma Connect accepts [token]"""
    self._request("/v1/me/", token)

  def _get(self, path: str):
    if self.public:
      return self._request(path, None)
    try:
      token = self.jwt_file.read_text().strip()
    except OSError:
      raise SourceError(f"no comma token at {self.jwt_file}")
    return self._request(path, token)

  def _request(self, path: str, token: str | None):
    req = urllib.request.Request(API + path, headers={"Authorization": f"JWT {token}"} if token else {})
    try:
      with urllib.request.urlopen(req, timeout=20, context=TLS) as r:
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
      if self.public and e.code in (401, 403, 404):
        raise SourceError("comma Connect says this is not public; its owner can turn on Public Access for it")
      hint = " (the token may have expired; get a new one from jwt.comma.ai)" if e.code in (401, 403) else ""
      raise SourceError(f"comma Connect answered {e.code}{hint}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
      raise SourceError(f"cannot reach comma Connect: {getattr(e, 'reason', e)}")

  def dongle(self) -> str:
    if self._dongle is None:
      devices = self.devices()
      mine = [d for d in devices if d.get("is_owner")] or devices
      if not mine:
        raise SourceError("no device on this comma account")
      self._dongle = os.environ.get("COMMA_DONGLE") or mine[0]["dongle_id"]
    return self._dongle

  def devices(self) -> list[dict]:
    return self._get("/v1/me/devices/")

  def device_online(self, within_s: int = 300) -> bool:
    import time
    devices = self.devices()
    ping = next((d.get("last_athena_ping") for d in devices if d["dongle_id"] == self.dongle()), None)
    return bool(ping) and time.time() - ping < within_s

  def listing(self, limit: int = 100) -> dict[str, dict]:
    """route name -> {segments, start_ms, end_ms, lat, lon, km}, newest first"""
    out = {}
    for r in self._get(f"/v1/devices/{self.dongle()}/routes_segments?limit={limit}"):
      out[r["fullname"].split("|", 1)[1]] = {"segments": r["segment_numbers"], "start_ms": r["start_time_utc_millis"],
                                             "end_ms": r["end_time_utc_millis"], **self._place(r)}
    return out

  @staticmethod
  def _place(r: dict) -> dict:
    # some drives start before GPS has a fix; Connect gives 0, 0 then
    start = (r.get("start_lat"), r.get("start_lng"))
    end = (r.get("end_lat"), r.get("end_lng"))
    lat, lon = start if any(start) else end
    return {"lat": lat, "lon": lon, "start": start, "end": end, "km": _km(r.get("distance"))}

  def route_info(self, route: str) -> dict:
    """the same as one entry of [listing], for a drive named directly, which may be too old to be in that list"""
    if route not in self._infos:
      self._infos[route] = self._lookup(route)
    return self._infos[route]

  def _lookup(self, route: str) -> dict:
    r = self._get(f"/v1/route/{self.dongle()}|{route}/")
    urls = self._urls(route)
    segments = sorted(set(urls.get("qlogs", {})) | set(urls.get("logs", {})))
    if not segments:
      raise SourceError(f"comma Connect has no files for {route}")

    def ms(text: str | None) -> int | None:
      return int(datetime.fromisoformat(text).replace(tzinfo=timezone.utc).timestamp() * 1000) if text else None

    return {"segments": segments, "start_ms": ms(r.get("start_time")), "end_ms": ms(r.get("end_time")), **self._place(r)}

  def best_detail(self, route: str, segments: list[int]) -> str:
    """the most this drive's files on Connect can show"""
    if not self.missing(route, segments, FULL_FILES):
      return "full"
    return "logs" if not self.missing(route, segments, LOGS_FILES) else "quick"

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
        # a file a copy from the comma left part-way is downloaded again in full
        if dest.exists() and not incomplete_marker(dest).exists():
          continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + ".part")
        try:
          with urllib.request.urlopen(urls[KINDS[name]][seg], timeout=60, context=TLS) as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
              f.write(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
          part.unlink(missing_ok=True)
          raise SourceError(f"download of {name} for segment {seg} failed: {getattr(e, 'reason', e)}")
        part.replace(dest)  # over a part-way copy, if there is one
        incomplete_marker(dest).unlink(missing_ok=True)
