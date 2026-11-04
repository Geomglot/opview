"""Fetch a route from the comma over SSH. Uses the `comma` host alias from ~/.ssh/config unless told otherwise, or
[ThroughServer]: the comma reached through comma's own SSH server, for when it is not on this network (comma prime)."""
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

REMOTE_ROOT = "/data/media/0/realdata"
_SEGMENT = re.compile(r"^(?P<route>[0-9a-f]{8}--[0-9a-f]{10})--(?P<seg>\d+)$")


# never stop to ask anything: nobody is at a terminal to answer. A comma not seen before is trusted on first contact.
OPTIONS = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new")

SERVER = "ssh.comma.ai"
_ALIAS = "comma-via-server"


@dataclass(frozen=True)
class ThroughServer:
  """The comma by its device id, through comma's SSH server, as openpilot's tools/scripts/ssh.py does. The options go
  in a settings file of the app's own rather than on the command line: ssh gives a file's settings to the second hop
  (to the comma) as well, but not -o options, and a file needs no quoting inside rsync's -e. It reads neither
  ~/.ssh/config nor ~/.ssh/known_hosts, so it names the key itself, and the servers it meets are kept in [folder]."""
  dongle: str
  folder: Path

  def config(self) -> str:
    self.folder.mkdir(parents=True, exist_ok=True)
    path = self.folder / "ssh_config"
    keys = "".join(f'  IdentityFile "{k.as_posix()}"\n' for k in comma_keys())
    path.write_text("Host *\n  BatchMode yes\n  ConnectTimeout 10\n  StrictHostKeyChecking accept-new\n"
                    f'  UserKnownHostsFile "{(self.folder / "known_hosts").as_posix()}"\n'
                    "  ServerAliveInterval 10\n  ServerAliveCountMax 3\n" + keys + "  IdentitiesOnly yes\n"
                    f"Host {_ALIAS}\n  HostName comma-{self.dongle}\n  User comma\n  ProxyJump comma-{self.dongle}@{SERVER}:22\n")
    # forward slashes: Windows' ssh drops the backslashes from a path it passes on to the second hop
    return path.as_posix()


def comma_keys() -> list[Path]:
  """the keys ssh would use for the comma on this network: those `ssh -G comma` names that exist, which takes in
  Include, Match and ssh's own defaults as reading ~/.ssh/config would not"""
  try:
    out = subprocess.run(["ssh", "-G", "comma"], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL).stdout
  except (OSError, subprocess.TimeoutExpired):
    out = ""
  keys = [Path(os.path.expanduser(line.split(None, 1)[1].strip())) for line in out.splitlines() if line.lower().startswith("identityfile ")]
  return [k for k in keys if k.exists()]


Host = str | ThroughServer


def _options(host: Host) -> tuple[str, ...]:
  return OPTIONS if isinstance(host, str) else ("-F", host.config())


def _name(host: Host) -> str:
  return host if isinstance(host, str) else _ALIAS


def run(host: Host, command: str) -> str:
  args = ["ssh", *_options(host), _name(host), command]
  if isinstance(host, ThroughServer):
    # two connections in a row (to comma's server, then on to the comma), and either can fail now and then and work a
    # moment later; ssh says 255 when it could not connect at all, so that is tried once more
    try:
      return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout
    except subprocess.CalledProcessError as e:
      if e.returncode != 255:
        raise
      import time
      time.sleep(2)
  return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout


def parse_listing(listing: str) -> dict[str, list[int]]:
  routes: dict[str, list[int]] = {}
  for name in listing.split():
    m = _SEGMENT.match(name)
    if m:
      routes.setdefault(m["route"], []).append(int(m["seg"]))
  return {route: sorted(segs) for route, segs in sorted(routes.items())}


def list_routes(host: Host) -> dict[str, list[int]]:
  return parse_listing(run(host, f"ls -1 {REMOTE_ROOT}"))


def is_metric(host: Host) -> bool:
  """the comma's own km or miles setting; as on the comma itself, no saved setting means miles"""
  return run(host, "cat /data/params/d/IsMetric 2>/dev/null; true").strip() == "1"


def _copy(command: list[str], cwd: Path | None = None, tick: Callable[[], None] | None = None) -> None:
  """run a copy, calling [tick] about once a second while it goes. Whatever [tick] raises (the job was cancelled) stops
  the copy and is raised from here. Without [tick] (the comma on this network) it is the plain call it always was."""
  if tick is None:
    subprocess.run(command, check=True, **({"cwd": cwd} if cwd is not None else {}))
    return
  proc = subprocess.Popen(command, cwd=cwd)
  try:
    while True:
      try:
        proc.wait(timeout=1)
        break
      except subprocess.TimeoutExpired:
        if tick:
          tick()
  except BaseException:
    # asked to stop rather than killed: rsync then keeps what it has under the file's own name, and the next copy only
    # sends the rest. Killed, it leaves a hidden temporary file that nothing reuses. (On Windows both are the same, and
    # scp's part-copy stays in the holding folder.)
    proc.terminate()
    try:
      proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
      proc.kill()
      proc.wait()
    raise
  if proc.returncode != 0:
    raise subprocess.CalledProcessError(proc.returncode, command)


def fetch(host: Host, route: str, segments: list[int], files: tuple[str, ...], cache: Path,
          tick: Callable[[], None] | None = None) -> None:
  """copy [files] of each segment into cache/<route>/<segment>/, skipping what is already complete"""
  if sys.platform == "win32":
    _fetch_with_scp(host, route, segments, files, cache, tick)
    return
  for seg in segments:
    local = cache / route / str(seg)
    local.mkdir(parents=True, exist_ok=True)
    sources = [f"{_name(host)}:{REMOTE_ROOT}/{route}--{seg}/{name}" for name in files]
    # each part quoted, for rsync splits -e on spaces; the options for the comma on this network have none to quote
    shell = " ".join(shlex.quote(part) for part in ("ssh", *_options(host)))
    _copy(["rsync", "-a", "--partial", "--timeout=30", "-e", shell, *sources, f"{local}/"], tick=tick)


# scp gives up on a comma that stops answering mid-copy after about 30 s, as rsync's --timeout=30 does
SCP_OPTIONS = (*OPTIONS, "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3")


def remote_sizes(host: Host, paths: list[str]) -> dict[str, int]:
  """sizes on the comma of those of [paths] (relative to REMOTE_ROOT) that are there"""
  listing = run(host, f"cd {REMOTE_ROOT} && stat -c '%s %n' {' '.join(paths)} 2>/dev/null; true")
  sizes = {}
  for line in listing.splitlines():
    size, _, name = line.partition(" ")
    if size.isdigit():
      sizes[name] = int(size)
  return sizes


def _fetch_with_scp(host: Host, route: str, segments: list[int], files: tuple[str, ...], cache: Path,
                    tick: Callable[[], None] | None = None) -> None:
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
    sources = [f"{_name(host)}:{REMOTE_ROOT}/{route}--{seg}/{name}" for name in needed]
    # run in the holding folder and copy to "."; a destination such as C:\... can be read as a host called C.
    # Through comma's server the settings file already holds the keep-alive options.
    options = SCP_OPTIONS if isinstance(host, str) else _options(host)
    _copy(["scp", "-q", *options, *sources, "."], cwd=holding, tick=tick)
    for name in needed:
      os.replace(holding / name, local / name)
    holding.rmdir()  # empty now; a copy cut short leaves it, with what arrived, to be overwritten next time
