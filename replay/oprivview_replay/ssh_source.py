"""Fetch a route from the comma over SSH. Uses the `comma` host alias from ~/.ssh/config unless told otherwise."""
import re
import subprocess
from pathlib import Path

REMOTE_ROOT = "/data/media/0/realdata"
_SEGMENT = re.compile(r"^(?P<route>[0-9a-f]{8}--[0-9a-f]{10})--(?P<seg>\d+)$")


def _ssh(host: str, command: str) -> str:
  return subprocess.run(["ssh", "-o", "ConnectTimeout=5", host, command], check=True, capture_output=True, text=True).stdout


def parse_listing(listing: str) -> dict[str, list[int]]:
  routes: dict[str, list[int]] = {}
  for name in listing.split():
    m = _SEGMENT.match(name)
    if m:
      routes.setdefault(m["route"], []).append(int(m["seg"]))
  return {route: sorted(segs) for route, segs in sorted(routes.items())}


def list_routes(host: str) -> dict[str, list[int]]:
  return parse_listing(_ssh(host, f"ls -1 {REMOTE_ROOT}"))


def is_metric(host: str) -> bool:
  """the comma's own km or miles setting; as on the comma itself, no saved setting means miles"""
  return _ssh(host, "cat /data/params/d/IsMetric 2>/dev/null; true").strip() == "1"


def fetch(host: str, route: str, segments: list[int], files: tuple[str, ...], cache: Path) -> None:
  """copy [files] of each segment into cache/<route>/<segment>/, skipping what is already complete"""
  for seg in segments:
    local = cache / route / str(seg)
    local.mkdir(parents=True, exist_ok=True)
    sources = [f"{host}:{REMOTE_ROOT}/{route}--{seg}/{name}" for name in files]
    subprocess.run(["rsync", "-a", "--partial", "--timeout=30", *sources, f"{local}/"], check=True)
