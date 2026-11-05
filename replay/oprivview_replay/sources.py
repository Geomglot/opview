"""Where a drive's files come from: the comma itself over SSH, or comma Connect (the cloud) with the JWT in ~/.comma/jwt.

Both put files in the same place, cache/<route>/<segment>/<file name>, so everything after the fetch is the same.
Connect usually has only the small files (qlog and qcamera); the comma has everything it has not yet deleted."""
import json
import os
import re
from datetime import datetime, timezone
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

import certifi

from . import ssh_source

API = "https://api.comma.ai"
ATHENA = "https://athena.comma.ai"  # the relay to the device itself
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

  def sizes(self, route: str, segments: list[int], names: tuple[str, ...]) -> dict[tuple[int, str], int]:
    """(segment, name) -> size on the comma, for those it has; empty if it cannot be asked just now"""
    try:
      found = ssh_source.remote_sizes(self.host, [f"{route}--{s}/{n}" for s in segments for n in names])
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
      return {}
    return {(s, n): found[f"{route}--{s}/{n}"] for s in segments for n in names if f"{route}--{s}/{n}" in found}

  def fetch(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path,
            progress: Callable[[int, int], None] | None = None) -> None:
    """[progress] is told, about once a second, how many bytes of the copy are here out of how many in all. Whatever it
    raises (the job was cancelled) stops the copy, and what has arrived stays for the next copy to finish."""
    if not self.through_server and progress is None:
      try:
        ssh_source.fetch(self.host, route, segments, names, cache)
      except subprocess.CalledProcessError as e:
        raise SourceError(f"could not copy {', '.join(names)} from {self.host}: {e}")
      return
    sizes = self.sizes(route, segments, names)
    tick = self._counter(route, cache, progress, sizes) if progress is not None else None
    try:
      ssh_source.fetch(self.host, route, segments, names, cache, tick)
    except BaseException as e:
      # a copy stopped part-way (Cancel, or the comma dropping off) keeps what came, under the file's own name, for the
      # next copy from the comma to finish. Mark those files, so that a download from Connect does not take them as whole.
      for s in segments:
        for n in names:
          f = cache / route / str(s) / n
          if f.exists() and f.stat().st_size != sizes.get((s, n)):
            incomplete_marker(f).touch()
      if isinstance(e, subprocess.CalledProcessError):
        where = "the comma through comma's server" if self.through_server else self.host
        raise SourceError(f"could not copy {', '.join(names)} from {where}: {e}")
      raise
    for s in segments:
      for n in names:
        incomplete_marker(cache / route / str(s) / n).unlink(missing_ok=True)

  @staticmethod
  def _counter(route: str, cache: Path, progress: Callable[[int, int], None],
               sizes: dict[tuple[int, str], int]) -> Callable[[], None]:
    """How much of each file is here, out of its size on the comma. A file can be in three places while it comes: under
    its own name (whole, or kept from a copy stopped part-way), as rsync's hidden .<name>.<random> beside it, or in
    scp's .part folder. The largest of them counts, so a resumed copy starts at what is already here and the count
    never goes backwards when rsync's new copy replaces the old part."""

    def arrived(s: int, n: str, size: int) -> int:
      folder = cache / route / str(s)
      places = [folder / n, folder / ".part" / n, *(folder.glob(f".{n}.*") if folder.exists() else ())]
      return min(size, max((_size(p) for p in places), default=0))

    total = sum(sizes.values())

    def tick() -> None:
      progress(sum(arrived(s, n, size) for (s, n), size in sizes.items()), total)
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
    return self._request(path, self._token())

  def _post(self, path: str, body: dict):
    return self._request(path, self._token(), body)

  def _token(self) -> str:
    try:
      return self.jwt_file.read_text().strip()
    except OSError:
      raise SourceError(f"no comma token at {self.jwt_file}")

  def _request(self, path: str, token: str | None, body: dict | None = None):
    headers = {"Authorization": f"JWT {token}"} if token else {}
    if body is not None:
      headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, headers=headers, data=None if body is None else json.dumps(body).encode(),
                                 method="GET" if body is None else "POST")
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

  def athena(self, method: str, params: dict | None = None, timeout: float = 15, expiry: int | None = None) -> object:
    """call [method] on the device itself through comma's relay (athena), as Connect's website does; SourceError if the
    relay or the device does not answer. With [expiry] (a Unix time) the relay keeps the call for a device that is
    offline until then, and answers "Device offline, message queued"."""
    token = self._token()
    body = {"method": method, "jsonrpc": "2.0", "id": 0, **({"params": params} if params is not None else {}),
            **({"expiry": expiry} if expiry is not None else {})}
    req = urllib.request.Request(f"{ATHENA}/{self.dongle()}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"JWT {token}", "Content-Type": "application/json"})
    try:
      with urllib.request.urlopen(req, timeout=timeout, context=TLS) as r:
        answer = json.loads(r.read())
    except urllib.error.HTTPError as e:
      raise SourceError(f"comma's relay answered {e.code}")
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
      raise SourceError(f"cannot reach comma's relay: {getattr(e, 'reason', e)}")
    if "error" in answer:
      raise SourceError(f"the comma did not answer: {answer['error']}")
    return answer.get("result")

  def request_upload(self, route: str, files: list[tuple[int, str]]) -> dict:
    """Ask the device to upload [files] (segment, name) of [route] to Connect, as Connect's website does: an upload
    address for each from comma's API, then uploadFilesToUrls through the relay. The device waits while its connection
    is metered (allow_cellular false leaves that to its own setting), and the relay keeps the request for 7 days if the
    device is offline. Returns {"offline": bool, "missing": [(segment, name) the device no longer has]}."""
    import time

    def names(name: str) -> tuple[str, ...]:  # a log may be kept under either name, as Connect's website also allows
      return (name, name.replace(".zst", ".bz2")) if name.endswith("log.zst") else (name,)

    paths = [(s, n, f"{route}--{s}/{alt}") for s, n in files for alt in names(n)]
    addresses = self._post(f"/v1/{self.dongle()}/upload_urls/", {"paths": [p for _, _, p in paths], "expiry_days": 7})
    files_data = [{"fn": p, "url": a["url"], "headers": a.get("headers") or {"x-ms-blob-type": "BlockBlob"},
                   "allow_cellular": False, "priority": 0} for (_, _, p), a in zip(paths, addresses)]
    result = self.athena("uploadFilesToUrls", {"files_data": files_data}, expiry=int(time.time()) + 7 * 86400)
    if not isinstance(result, dict):  # "Device offline, message queued"
      return {"offline": True, "missing": []}
    failed = set(result.get("failed") or [])
    return {"offline": False, "missing": [(s, n) for s, n in files if all(f"{route}--{s}/{alt}" in failed for alt in names(n))]}

  def upload_queue(self) -> list[dict] | None:
    """what the device is uploading or has waiting, as {route, segment, file, progress (0 to 1), current}; None when the
    device does not answer"""
    try:
      items = self.athena("listUploadQueue") or []
    except SourceError:
      return None
    out = []
    for item in items:
      parts = item.get("url", "").split("?")[0].split("/")
      if len(parts) >= 4 and parts[-2].isdigit():
        out.append({"route": parts[-3], "segment": int(parts[-2]), "file": parts[-1],
                    "progress": float(item.get("progress") or 0), "current": bool(item.get("current"))})
    return out

  def forget_route(self, route: str) -> None:
    """look again at what Connect has for [route], as after an upload"""
    self._files.pop(route, None)
    self._infos.pop(route, None)

  def network(self) -> dict | None:
    """{"kind": "Wi-Fi" or "cellular" or ..., "metered": bool} as the comma reports its connection now, or None when it
    does not answer. Metered is the comma's own setting: Wi-Fi Network Metered, or Cellular Metered."""
    try:
      state = (self.athena("getMessage", {"service": "deviceState", "timeout": 5000}) or {}).get("deviceState")
    except SourceError:
      return None
    if not state or "networkMetered" not in state:
      return None
    kind = str(state.get("networkType", ""))
    names = {"wifi": "Wi-Fi", "ethernet": "a wired connection", "none": "no connection"}
    return {"kind": names.get(kind, "cellular" if kind.startswith("cell") else kind or "an unknown connection"),
            "metered": bool(state["networkMetered"])}

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

  def sizes(self, route: str, segments: list[int], names: tuple[str, ...]) -> dict[tuple[int, str], int]:
    """(segment, name) -> size on Connect, asked of its file store a few at a time; those it does not say are left out"""
    from concurrent.futures import ThreadPoolExecutor
    urls = self._urls(route)
    wanted = [(s, n) for s in segments for n in names if s in urls.get(KINDS[n], {})]

    def size(item: tuple[int, str]) -> int | None:
      s, n = item
      try:
        with urllib.request.urlopen(urllib.request.Request(urls[KINDS[n]][s], method="HEAD"), timeout=20, context=TLS) as r:
          length = r.headers.get("Content-Length")
          return int(length) if length and length.isdigit() else None
      except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None

    with ThreadPoolExecutor(8) as pool:
      return {item: got for item, got in zip(wanted, pool.map(size, wanted)) if got is not None}

  def fetch(self, route: str, segments: list[int], names: tuple[str, ...], cache: Path,
            progress: Callable[[int, int], None] | None = None) -> None:
    """[progress] is told, about once a second, how many bytes have come out of how many in all. Whatever it raises
    (the job was cancelled) stops the download: the files already whole stay, and the one part-way is dropped."""
    gone = self.missing(route, segments, names)
    if gone:
      raise SourceError(f"comma Connect does not have {', '.join(gone)} for this drive (it was never uploaded)")
    urls = self._urls(route)
    # a file a copy from the comma left part-way is downloaded again in full
    wanted = [(s, n) for s in segments for n in names
              if not ((d := cache / route / str(s) / n).exists() and not incomplete_marker(d).exists())]
    sizes = self.sizes(route, segments, names) if progress is not None and wanted else {}
    done, last = 0, 0.0

    def total() -> int:
      """all of it: a file the store gave no size for counts as the others of its kind do"""
      def typical(name: str) -> float:
        like = [sizes[i] for i in wanted if i in sizes and i[1] == name] or [sizes[i] for i in wanted if i in sizes]
        return sum(like) / len(like) if like else 0
      return round(sum(sizes[i] if i in sizes else typical(i[1]) for i in wanted))

    def report(force: bool = False) -> None:
      nonlocal last
      if progress is not None and (force or time.monotonic() - last >= 1):
        last = time.monotonic()
        progress(done, max(done, total()))

    report(force=True)
    for seg, name in wanted:
      dest = cache / route / str(seg) / name
      dest.parent.mkdir(parents=True, exist_ok=True)
      part = dest.with_name(dest.name + ".part")
      start = done
      try:
        with urllib.request.urlopen(urls[KINDS[name]][seg], timeout=60, context=TLS) as r, open(part, "wb") as f:
          while chunk := r.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            report()
      except (urllib.error.URLError, TimeoutError, OSError) as e:
        part.unlink(missing_ok=True)
        raise SourceError(f"download of {name} for segment {seg} failed: {getattr(e, 'reason', e)}")
      except BaseException:  # cancelled: only whole files are kept
        part.unlink(missing_ok=True)
        raise
      sizes[(seg, name)] = done - start  # its real size, for the total
      part.replace(dest)  # over a part-way copy, if there is one
      incomplete_marker(dest).unlink(missing_ok=True)
    report(force=True)
