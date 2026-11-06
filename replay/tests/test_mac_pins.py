"""What the replay server does on a Mac, pinned before the Windows port.

Today's code ignores the platform, so these pass now. After the port they keep passing only if the macOS branch
returns exactly these values. Each test forces macOS, because CI runs them on Ubuntu. They are skipped on real Windows,
where HOME and forward slashes cannot be forced this way.
"""
import importlib
import inspect
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from oprivview_replay import admin, cli, render, server, settings, ssh_source

pytestmark = pytest.mark.skipif(sys.platform == "win32", reason="a Mac cannot be imitated on real Windows")

ROUTE = "00000059--5e374df67a"
RELOADED = (settings, cli, server)  # in import order, as server copies its defaults from the other two


@pytest.fixture
def mac(monkeypatch, tmp_path):
  monkeypatch.setattr(sys, "platform", "darwin")
  monkeypatch.setenv("HOME", str(tmp_path))
  return tmp_path


@pytest.fixture
def mac_modules(tmp_path):
  """for values worked out on import: load the modules again as a Mac would, and put them back afterwards"""
  with pytest.MonkeyPatch.context() as mp:
    mp.setattr(sys, "platform", "darwin")
    mp.setenv("HOME", str(tmp_path))
    for module in RELOADED:
      importlib.reload(module)
    yield tmp_path
  for module in RELOADED:
    importlib.reload(module)


def test_cache_folder(mac_modules):
  # Mac value pinned before the Windows port; must not change on darwin.
  assert cli.DEFAULT_CACHE == mac_modules / "Library/Caches/GeoRivViewReplay"


def test_built_renderer_path(mac_modules):
  # Mac value pinned before the Windows port; must not change on darwin.
  assert str(cli.DEFAULT_APP).endswith("build/macos/Build/Products/Release/GeoRivView Replay.app/Contents/MacOS/GeoRivView Replay")


def test_settings_file(mac_modules):
  # Mac value pinned before the Windows port; must not change on darwin.
  assert settings.DEFAULT_FILE == mac_modules / "Library/Application Support/GeoRivViewReplay/settings.json"


def test_default_output_folder(mac_modules):
  # Mac value pinned before the Windows port; must not change on darwin.
  # Reads the default of make_app; if the port moves this into a function, read it from there instead.
  assert inspect.signature(server.make_app).parameters["output_dir"].default == mac_modules / "Movies"


def test_job_file_asks_for_the_mac_hardware_encoder(mac, tmp_path, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  monkeypatch.setattr(render, "write_clip", lambda *a, **k: ([], 30, []))
  monkeypatch.setattr(render, "_tool", lambda name: f"/bundled/{name}")
  start = SimpleNamespace(frame=0)
  job = render.prepare(None, tmp_path, start, start, {"camera": "road", "video_width": 1280}, tmp_path / "out.mp4", progress=lambda text: None)
  assert json.loads(job.read_text())["encoder"] == "h264_videotoolbox"


def test_ffmpeg_shipped_with_the_app_comes_first(mac, tmp_path, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  (tmp_path / "ffmpeg").write_text("")
  monkeypatch.setenv("OPRIVVIEW_FFMPEG_DIR", str(tmp_path))
  assert render._tool("ffmpeg") == str(tmp_path / "ffmpeg")


def test_ffmpeg_is_otherwise_looked_for_on_the_path_then_in_homebrew(mac, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  monkeypatch.delenv("OPRIVVIEW_FFMPEG_DIR", raising=False)
  calls = []

  def which(name, path=None):
    calls.append((name, path))
    return "/opt/homebrew/bin/ffmpeg" if path else None

  monkeypatch.setattr(shutil, "which", which)
  assert render._tool("ffmpeg") == "/opt/homebrew/bin/ffmpeg"
  assert calls == [("ffmpeg", None), ("ffmpeg", "/usr/local/bin:/opt/homebrew/bin")]


def test_files_are_fetched_from_the_comma_with_rsync(mac, tmp_path, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  calls = []
  monkeypatch.setattr(ssh_source.subprocess, "run", lambda args, **kw: calls.append((args, kw)))
  ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst", "fcamera.hevc"), tmp_path)
  assert calls == [(["rsync", "-a", "--partial", "--timeout=30", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new",
                     f"comma:/data/media/0/realdata/{ROUTE}--3/rlog.zst", f"comma:/data/media/0/realdata/{ROUTE}--3/fcamera.hevc",
                     f"{tmp_path}/{ROUTE}/3/"], {"check": True})]


def test_commands_run_on_the_comma_through_ssh(mac, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  calls = []

  def run(args, **kw):
    calls.append((args, kw))
    return SimpleNamespace(stdout="done")

  monkeypatch.setattr(ssh_source.subprocess, "run", run)
  assert ssh_source.run("comma", "true") == "done"
  assert calls == [(["ssh", *ssh_source.OPTIONS, "comma", "true"], {"check": True, "capture_output": True, "text": True, "timeout": 20})]


def test_network_scan_asks_ifconfig(mac, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  calls = []

  def run(args, **kw):
    calls.append(args)
    return SimpleNamespace(stdout="")

  monkeypatch.setattr(admin.subprocess, "run", run)
  assert admin.local_prefixes() == []
  assert calls == [["/sbin/ifconfig"]]


def test_network_scan_reads_mac_ifconfig_output(mac):
  # Mac value pinned before the Windows port; must not change on darwin.
  text = """lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
\tinet6 ::1 prefixlen 128
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet6 fe80::1c2b:3a4d:5e6f:7081%en0 prefixlen 64 secured scopeid 0xe
\tinet 192.168.4.27 netmask 0xffffff00 broadcast 192.168.4.255
en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 169.254.10.2 netmask 0xffff0000 broadcast 169.254.255.255
"""
  assert admin.local_prefixes(text) == ["192.168.4"]


def test_server_stops_when_the_app_that_started_it_goes_away(mac, monkeypatch):
  # Mac value pinned before the Windows port; must not change on darwin.
  class Exited(Exception):
    pass

  class FakeThread:
    made: list = []

    def __init__(self, target, daemon):
      self.target, self.daemon = target, daemon
      self.made.append(self)

    def start(self):
      pass

  def leave(code):
    raise Exited(code)

  parents = iter([100, 100, 100, 200])  # the first is the one remembered; then the app is still there twice, then gone
  monkeypatch.setattr(server.os, "getppid", lambda: next(parents))
  monkeypatch.setattr(server.os, "_exit", leave)
  monkeypatch.setattr(server.time, "sleep", lambda seconds: None)
  monkeypatch.setattr(server.threading, "Thread", FakeThread)
  monkeypatch.setattr(server, "Settings", lambda *a: None)
  monkeypatch.setattr(server.folders, "move_old", lambda: [])  # not the folders of whoever runs the tests
  monkeypatch.setattr(server, "make_app", lambda *a, **k: "app")
  monkeypatch.setattr(server.uvicorn, "run", lambda *a, **k: None)
  monkeypatch.setattr(sys, "argv", ["server", "--exit-with-parent", "--no-connect"])

  server.main()

  assert [t.daemon for t in FakeThread.made] == [True]
  with pytest.raises(Exited) as exited:
    FakeThread.made[0].target()
  assert exited.value.args == (0,)
  assert list(parents) == []  # it stopped at the first sign of change, having checked each time
