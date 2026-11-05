"""What the replay server does on Linux that it does not do elsewhere. These imitate Linux, so they run everywhere."""
import importlib
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from oprivview_replay import admin, cli, render, server, settings, ssh_source

RELOADED = (settings, cli, server)  # in import order, as server copies its defaults from the other two
ROUTE = "00000059--5e374df67a"

BUNDLED = "/app/ffmpeg/ffmpeg"
OWN = "/usr/bin/ffmpeg"


@pytest.fixture
def linux(tmp_path, monkeypatch):  # tmp_path first: pytest makes it differently on a computer it takes for Linux
  monkeypatch.setattr(sys, "platform", "linux")
  monkeypatch.setattr(render, "_linux_encodings", {})


def _computer(monkeypatch, working: set[tuple[str, str, str | None]], devices=("/dev/dri/renderD128",), own: str | None = OWN):
  """a computer where only [working] (ffmpeg, encoder, device) encode; returns what was tried, in order"""
  tried = []

  def run(args, **kw):
    device = args[args.index("-vaapi_device") + 1] if "-vaapi_device" in args else None
    attempt = (args[0], args[args.index("-c:v") + 1], device)
    tried.append(attempt)
    if attempt not in working:
      raise subprocess.CalledProcessError(1, args)

  monkeypatch.setattr(render.subprocess, "run", run)
  monkeypatch.setattr(render.glob, "glob", lambda pattern: list(devices))
  monkeypatch.setattr(render.shutil, "which", lambda name, path=None: own)
  return tried


def test_nvidia_comes_first(linux, monkeypatch):
  _computer(monkeypatch, {(BUNDLED, "h264_nvenc", None), (BUNDLED, "h264_vaapi", "/dev/dri/renderD128")})
  assert render.encoding(BUNDLED) == render.Encoding(BUNDLED, "h264_nvenc")


def test_vaapi_is_tried_on_each_graphics_device(linux, monkeypatch):
  tried = _computer(monkeypatch, {(BUNDLED, "h264_vaapi", "/dev/dri/renderD129")},
                    devices=("/dev/dri/renderD129", "/dev/dri/renderD128"))
  assert render.encoding(BUNDLED) == render.Encoding(BUNDLED, "h264_vaapi", "/dev/dri/renderD129")
  assert tried == [(BUNDLED, "h264_nvenc", None), (BUNDLED, "h264_vaapi", "/dev/dri/renderD128"),
                   (BUNDLED, "h264_vaapi", "/dev/dri/renderD129")]


def test_vaapi_frames_are_uploaded_to_the_graphics_card(linux, monkeypatch):
  seen = []
  monkeypatch.setattr(render.subprocess, "run", lambda args, **kw: seen.append(args))
  assert render._encodes(BUNDLED, "h264_vaapi", "/dev/dri/renderD128")
  args = seen[0]
  assert args[args.index("-vaapi_device") + 1] == "/dev/dri/renderD128" and args.index("-vaapi_device") < args.index("-i")
  assert args[args.index("-vf") + 1] == "format=nv12,hwupload" and args.index("-vf") > args.index("-i")


def test_without_a_graphics_encoder_the_computers_own_ffmpeg_encodes(linux, monkeypatch):
  tried = _computer(monkeypatch, {(OWN, "libx264", None)}, devices=())
  assert render.encoding(BUNDLED) == render.Encoding(OWN, "libx264")
  assert render.encoding(BUNDLED) == render.Encoding(OWN, "libx264") and len(tried) == 2  # asked once, then remembered


def test_with_neither_it_says_what_to_install(linux, monkeypatch):
  _computer(monkeypatch, set(), own=None)
  with pytest.raises(RuntimeError, match="sudo apt install ffmpeg"):
    render.encoding(BUNDLED)


def test_the_apps_own_ffmpeg_is_not_tried_twice(linux, monkeypatch):
  # run from a source checkout, _tool finds the computer's ffmpeg in the first place; it has no fallback then
  tried = _computer(monkeypatch, set(), devices=())
  with pytest.raises(RuntimeError):
    render.encoding(OWN)
  assert tried == [(OWN, "h264_nvenc", None)]


def test_a_vaapi_job_names_its_device_and_others_do_not(tmp_path, linux, monkeypatch):
  monkeypatch.setattr(render, "write_clip", lambda *a, **k: ([], 30, []))
  monkeypatch.setattr(render, "_tool", lambda name: BUNDLED)
  start = SimpleNamespace(frame=0)
  settings = {"camera": "road", "video_width": 1280}
  for how in (render.Encoding(BUNDLED, "h264_vaapi", "/dev/dri/renderD128"), render.Encoding(OWN, "libx264")):
    monkeypatch.setattr(render, "encoding", lambda ffmpeg, how=how: how)
    job = json.loads(render.prepare(None, tmp_path, start, start, settings, tmp_path / "o.mp4", progress=lambda t: None).read_text())
    assert (job["ffmpeg"], job["encoder"], job.get("encoder_device")) == (how.ffmpeg, how.encoder, how.device)
    assert ("encoder_device" in job) == (how.device is not None)


@pytest.fixture
def linux_modules(tmp_path):
  """for values worked out on import: load the modules again as Linux would, and put them back afterwards"""
  def load(videos: str = ""):
    with pytest.MonkeyPatch.context() as mp:
      mp.setattr(sys, "platform", "linux")
      mp.setenv("HOME", str(tmp_path))
      mp.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
      mp.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
      mp.setattr(Path, "home", classmethod(lambda cls: tmp_path))
      mp.setattr(subprocess, "run", lambda args, **kw: SimpleNamespace(stdout=videos + "\n"))
      for module in RELOADED:
        importlib.reload(module)
  yield load
  for module in RELOADED:
    importlib.reload(module)


@pytest.mark.skipif(sys.platform == "win32", reason="Linux folders cannot be imitated on real Windows")
def test_folders_are_the_linux_ones(linux_modules, tmp_path):
  linux_modules(str(tmp_path / "Vidéos"))
  assert cli.DEFAULT_CACHE == tmp_path / "cache/OPRivViewReplay"
  assert settings.DEFAULT_FILE == tmp_path / "config/OPRivViewReplay/settings.json"
  assert server.DEFAULT_OUTPUT_DIR == tmp_path / "Vidéos"  # the desktop's own name for it
  assert str(cli.DEFAULT_APP).endswith("build/linux/x64/release/bundle/oprivview-replay")


@pytest.mark.skipif(sys.platform == "win32", reason="Linux folders cannot be imitated on real Windows")
def test_with_no_videos_folder_set_clips_go_to_videos_in_home(linux_modules, tmp_path):
  linux_modules(str(tmp_path))  # xdg-user-dir answers the home folder when none is set
  assert server.DEFAULT_OUTPUT_DIR == tmp_path / "Videos"


def test_network_scan_asks_ip(linux, monkeypatch):
  calls = []

  def run(args, **kw):
    calls.append(args)
    return SimpleNamespace(stdout="2: enp1s0    inet 192.168.4.20/24 brd 192.168.4.255 scope global enp1s0\n"
                                  "1: lo    inet 127.0.0.1/8 scope host lo\n")

  monkeypatch.setattr(admin.subprocess, "run", run)
  assert admin.local_prefixes() == ["192.168.4"]
  assert calls == [["ip", "-4", "-o", "addr", "show"]]


def test_without_rsync_files_are_copied_with_scp(tmp_path, linux, monkeypatch):
  monkeypatch.setattr(ssh_source.shutil, "which", lambda name: None)
  used = []
  monkeypatch.setattr(ssh_source, "_fetch_with_scp", lambda *a: used.append(a))
  ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst",), tmp_path)
  assert len(used) == 1


def test_with_rsync_files_are_copied_with_rsync(tmp_path, linux, monkeypatch):
  monkeypatch.setattr(ssh_source.shutil, "which", lambda name: "/usr/bin/rsync")
  calls = []
  monkeypatch.setattr(ssh_source.subprocess, "run", lambda args, **kw: calls.append(args))
  ssh_source.fetch("comma", ROUTE, [3], ("rlog.zst",), tmp_path)
  assert calls[0][0] == "rsync"
