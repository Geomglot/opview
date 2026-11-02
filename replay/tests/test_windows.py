"""What the replay server does on Windows. Run on real Windows only: these use Windows itself (process handles, the
Windows folders, ffmpeg.exe), which cannot be imitated elsewhere. The Mac's own behaviour is pinned in test_mac_pins.py."""
import os
import subprocess
import sys
import threading

import pytest

from oprivview_replay import admin, cli, render, server, settings

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows only")


def test_folders_are_the_windows_ones():
  assert cli.DEFAULT_CACHE.parent == cli.Path(os.environ["LOCALAPPDATA"]) / "OPRivViewReplay"
  assert settings.DEFAULT_FILE == cli.Path(os.environ["APPDATA"]) / "OPRivViewReplay/settings.json"
  assert server.DEFAULT_OUTPUT_DIR == cli.Path.home() / "Videos"
  assert cli.DEFAULT_APP.name == "OPRivViewReplay.exe"


def test_ffmpeg_shipped_with_the_app_is_found_by_its_exe_name(tmp_path, monkeypatch):
  (tmp_path / "ffmpeg.exe").write_text("")
  monkeypatch.setenv("OPRIVVIEW_FFMPEG_DIR", str(tmp_path))
  assert render._tool("ffmpeg") == str(tmp_path / "ffmpeg.exe")


def test_ffmpeg_is_otherwise_looked_for_on_the_path_only(monkeypatch):
  monkeypatch.delenv("OPRIVVIEW_FFMPEG_DIR", raising=False)
  calls = []
  monkeypatch.setattr(render.shutil, "which", lambda name, path=None: calls.append((name, path)))
  with pytest.raises(FileNotFoundError):
    render._tool("ffmpeg")
  assert calls == [("ffmpeg", None)]


def _encoders_that_work(monkeypatch, working: set[str]):
  tried = []

  def run(args, **kw):
    name = args[args.index("-c:v") + 1]
    tried.append(name)
    if name not in working:
      raise subprocess.CalledProcessError(1, args)

  monkeypatch.setattr(render.subprocess, "run", run)
  monkeypatch.setattr(render, "_encoders", {})
  return tried


def test_the_graphics_card_encoder_is_used_when_it_really_works(monkeypatch):
  tried = _encoders_that_work(monkeypatch, {"h264_qsv", "h264_mf"})
  assert render.encoder("ffmpeg.exe") == "h264_qsv"
  assert tried == ["h264_nvenc", "h264_qsv"]
  assert render.encoder("ffmpeg.exe") == "h264_qsv" and len(tried) == 2  # asked once, then remembered


def test_windows_own_encoder_is_the_last_resort(monkeypatch):
  _encoders_that_work(monkeypatch, {"h264_mf"})
  assert render.encoder("ffmpeg.exe") == "h264_mf"


def test_no_encoder_at_all_says_what_to_do(monkeypatch):
  tried = _encoders_that_work(monkeypatch, set())
  with pytest.raises(RuntimeError, match="Media Feature Pack"):
    render.encoder("ffmpeg.exe")
  assert tried == list(render.WINDOWS_ENCODERS)


def test_network_scan_reads_this_computers_own_addresses(monkeypatch):
  monkeypatch.setattr(admin.socket, "getaddrinfo", lambda *a: [(2, 1, 6, "", ("192.168.4.27", 0)), (2, 1, 6, "", ("127.0.0.1", 0)),
                                                             (2, 1, 6, "", ("169.254.10.2", 0)), (2, 1, 6, "", ("10.0.0.5", 0))])
  monkeypatch.setattr(admin.subprocess, "run", lambda *a, **k: pytest.fail("Windows has no ifconfig to ask"))
  assert admin.local_prefixes() == ["10.0.0", "192.168.4"]


def test_server_stops_when_the_app_that_started_it_goes_away(monkeypatch):
  parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1)"])
  exited = threading.Event()
  monkeypatch.setattr(server.os, "_exit", lambda code: exited.set())
  threading.Thread(target=server._windows_parent_watch(parent.pid), daemon=True).start()
  assert not exited.wait(0.3)  # still there
  parent.wait()
  assert exited.wait(5)


def test_a_parent_already_gone_stops_the_server_at_once(monkeypatch):
  parent = subprocess.Popen([sys.executable, "-c", "pass"])
  parent.wait()
  exited = threading.Event()
  monkeypatch.setattr(server.os, "_exit", lambda code: exited.set())
  server._windows_parent_watch(parent.pid)()
  assert exited.is_set()
