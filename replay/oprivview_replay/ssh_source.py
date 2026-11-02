"""Fetch a route from the comma over SSH. Uses the `comma` host alias from ~/.ssh/config unless told otherwise."""
import os
import re
import subprocess
import sys
from pathlib import Path

REMOTE_ROOT = "/data/media/0/realdata"
_SEGMENT = re.compile(r"^(?P<route>[0-9a-f]{8}--[0-9a-f]{10})--(?P<seg>\d+)$")


# never stop to ask anything: nobody is at a terminal to answer. A comma not seen before is trusted on first contact.
OPTIONS = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new")


def run(host: str, command: str) -> str:
  return subprocess.run(["ssh", *OPTIONS, host, command], check=True, capture_output=True, text=True, timeout=20).stdout


def parse_listing(listing: str) -> dict[str, list[int]]:
  routes: dict[str, list[int]] = {}
  for name in listing.split():
    m = _SEGMENT.match(name)
    if m:
      routes.setdefault(m["route"], []).append(int(m["seg"]))
  return {route: sorted(segs) for route, segs in sorted(routes.items())}


def list_routes(host: str) -> dict[str, list[int]]:
  return parse_listing(run(host, f"ls -1 {REMOTE_ROOT}"))


def is_metric(host: str) -> bool:
  """the comma's own km or miles setting; as on the comma itself, no saved setting means miles"""
  return run(host, "cat /data/params/d/IsMetric 2>/dev/null; true").strip() == "1"


def fetch(host: str, route: str, segments: list[int], files: tuple[str, ...], cache: Path) -> None:
  """copy [files] of each segment into cache/<route>/<segment>/, skipping what is already complete"""
  if sys.platform == "win32":
    _fetch_with_scp(host, route, segments, files, cache)
    return
  for seg in segments:
    local = cache / route / str(seg)
    local.mkdir(parents=True, exist_ok=True)
    sources = [f"{host}:{REMOTE_ROOT}/{route}--{seg}/{name}" for name in files]
    subprocess.run(["rsync", "-a", "--partial", "--timeout=30", "-e", " ".join(("ssh", *OPTIONS)), *sources, f"{local}/"], check=True)


# scp gives up on a comma that stops answering mid-copy after about 30 s, as rsync's --timeout=30 does
SCP_OPTIONS = (*OPTIONS, "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3")


def remote_sizes(host: str, paths: list[str]) -> dict[str, int]:
  """sizes on the comma of those of [paths] (relative to REMOTE_ROOT) that are there"""
  listing = run(host, f"cd {REMOTE_ROOT} && stat -c '%s %n' {' '.join(paths)} 2>/dev/null; true")
  sizes = {}
  for line in listing.splitlines():
    size, _, name = line.partition(" ")
    if size.isdigit():
      sizes[name] = int(size)
  return sizes


def _fetch_with_scp(host: str, route: str, segments: list[int], files: tuple[str, ...], cache: Path) -> None:
  """Windows has no rsync. Its own OpenSSH has scp, which uses the same ssh config, keys and known hosts as [run].
  scp cannot skip what is already here, so ask the comma for its sizes first and copy only files that differ. Copies go
  to a holding folder and move into place when whole, so a copy cut short never passes for a complete file."""
  wanted = [f"{route}--{seg}/{name}" for seg in segments for name in files]
  try:
    sizes = remote_sizes(host, wanted)
  except subprocess.TimeoutExpired as e:  # the caller reports a failed copy, as it does when rsync cannot connect
    raise subprocess.CalledProcessError(255, e.cmd, stderr=f"{host} did not answer") from e
  for seg in segments:
    local = cache / route / str(seg)
    local.mkdir(parents=True, exist_ok=True)
    needed = [name for name in files
              if not ((local / name).exists() and (local / name).stat().st_size == sizes.get(f"{route}--{seg}/{name}"))]
    if not needed:
      continue
    holding = local / ".part"
    holding.mkdir(exist_ok=True)
    sources = [f"{host}:{REMOTE_ROOT}/{route}--{seg}/{name}" for name in needed]
    # run in the holding folder and copy to "."; a destination such as C:\... can be read as a host called C
    subprocess.run(["scp", "-q", *SCP_OPTIONS, *sources, "."], check=True, cwd=holding)
    for name in needed:
      os.replace(holding / name, local / name)
