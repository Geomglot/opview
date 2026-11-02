"""What the replay server does on Windows. Run on real Windows only: these use Windows itself (process handles, the
Windows folders, ffmpeg.exe), which cannot be imitated elsewhere. The Mac's own behaviour is pinned in test_mac_pins.py."""
import os
import subprocess
import sys
import threading
from types import SimpleNamespace

import pytest

from oprivview_replay import admin, cli, render, server, settings, ssh_source

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


ROUTE = "00000059--5e374df67a"


class FakeComma:
  """answers the size question over ssh and 'copies' with scp by writing [content] into the folder scp is run in"""

  def __init__(self, monkeypatch, files: dict[str, bytes], fail_copy: bool = False):
    self.files, self.fail_copy, self.calls = files, fail_copy, []
    monkeypatch.setattr(ssh_source.subprocess, "run", self.run)

  def run(self, args, **kw):
    self.calls.append((args, kw))
    if args[0] == "ssh":
      listing = "".join(f"{len(self.files[p])} {p}\n" for p in args[-1].split("2>/dev/null")[0].split()[6:] if p in self.files)
      return SimpleNamespace(stdout=listing)
    assert args[0] == "scp" and args[-1] == "." and kw["check"] is True
    if self.fail_copy:
      raise subprocess.CalledProcessError(1, args)
    for source in args[1:-1]:
      if source.startswith("comma:"):
        (kw["cwd"] / source.rsplit("/", 1)[1]).write_bytes(self.files[source.split("realdata/", 1)[1]])

  def copies(self):
    return [[a for a in args if a.startswith("comma:")] for args, kw in self.calls if args[0] == "scp"]


def test_fetch_asks_sizes_once_and_copies_each_segment_with_scp(monkeypatch, tmp_path):
  comma = FakeComma(monkeypatch, {f"{ROUTE}--3/rlog.zst": b"log3", f"{ROUTE}--3/fcamera.hevc": b"video3",
                                  f"{ROUTE}--4/rlog.zst": b"log4", f"{ROUTE}--4/fcamera.hevc": b"video4"})
  ssh_source.fetch("comma", ROUTE, [3, 4], ("rlog.zst", "fcamera.hevc"), tmp_path)
  assert [args[0] for args, kw in comma.calls] == ["ssh", "scp", "scp"]
  assert comma.copies() == [[f"comma:/data/media/0/realdata/{ROUTE}--3/rlog.zst", f"comma:/data/media/0/realdata/{ROUTE}--3/fcamera.hevc"],
                            [f"comma:/data/media/0/realdata/{ROUTE}--4/rlog.zst", f"comma:/data/media/0/realdata/{ROUTE}--4/fcamera.hevc"]]
  assert (tmp_path / ROUTE / "4" / "fcamera.hevc").read_bytes() == b"video4"
  assert not (tmp_path / ROUTE / "3" / ".part").exists()  # everything moved into place, and the holding folder gone
  scp = next(args for args, kw in comma.calls if args[0] == "scp")
  assert "BatchMode=yes" in scp and "StrictHostKeyChecking=accept-new" in scp and "ServerAliveInterval=10" in scp


def test_fetch_skips_files_already_whole_and_recopies_ones_that_differ(monkeypatch, tmp_path):
  comma = FakeComma(monkeypatch, {f"{ROUTE}--3/rlog.zst": b"log3", f"{ROUTE}--3/fcamera.hevc": b"video3"})
  local = tmp_path / ROUTE / "3"
  local.mkdir(parents=True)
  (local / "rlog.zst").write_bytes(b"log3")  # whole
  (local / "fcamera.hevc").write_bytes(b"vid")  # cut short
  ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst", "fcamera.hevc"), tmp_path)
  assert comma.copies() == [[f"comma:/data/media/0/realdata/{ROUTE}--3/fcamera.hevc"]]
  assert (local / "fcamera.hevc").read_bytes() == b"video3"


def test_fetch_with_everything_here_does_not_copy_at_all(monkeypatch, tmp_path):
  comma = FakeComma(monkeypatch, {f"{ROUTE}--3/qlog.zst": b"q"})
  (tmp_path / ROUTE / "3").mkdir(parents=True)
  (tmp_path / ROUTE / "3" / "qlog.zst").write_bytes(b"q")
  ssh_source.fetch("comma", ROUTE, [3], ("qlog.zst",), tmp_path)
  assert comma.copies() == []


def test_a_failed_copy_leaves_no_file_under_its_real_name(monkeypatch, tmp_path):
  FakeComma(monkeypatch, {f"{ROUTE}--3/rlog.zst": b"log3"}, fail_copy=True)
  with pytest.raises(subprocess.CalledProcessError):
    ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst",), tmp_path)
  assert not (tmp_path / ROUTE / "3" / "rlog.zst").exists()


def test_a_file_the_comma_does_not_have_is_still_asked_for_so_the_copy_fails(monkeypatch, tmp_path):
  comma = FakeComma(monkeypatch, {}, fail_copy=True)
  with pytest.raises(subprocess.CalledProcessError):
    ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst",), tmp_path)
  assert comma.copies() == [[f"comma:/data/media/0/realdata/{ROUTE}--3/rlog.zst"]]


def test_a_comma_that_does_not_answer_is_a_failed_copy(monkeypatch, tmp_path):
  def run(args, **kw):
    raise subprocess.TimeoutExpired(args, 20)

  monkeypatch.setattr(ssh_source.subprocess, "run", run)
  with pytest.raises(subprocess.CalledProcessError):
    ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst",), tmp_path)


def test_the_server_watches_the_app_it_is_told_about_rather_than_a_launcher(monkeypatch):
  watched = []
  monkeypatch.setattr(server, "_windows_parent_watch", lambda pid: watched.append(pid) or (lambda: None))
  monkeypatch.setattr(server.threading, "Thread", lambda target, daemon: SimpleNamespace(start=lambda: None))
  monkeypatch.setattr(server, "Settings", lambda: None)
  monkeypatch.setattr(server, "make_app", lambda *a, **k: "app")
  monkeypatch.setattr(server.uvicorn, "run", lambda *a, **k: None)
  monkeypatch.setattr(sys, "argv", ["server", "--exit-with-parent", "--parent-pid", "4242", "--no-connect"])
  server.main()
  monkeypatch.setattr(sys, "argv", ["server", "--exit-with-parent", "--no-connect"])
  server.main()
  assert watched == [4242, os.getppid()]
