"""What the replay server does on Linux that it does not do elsewhere. These imitate Linux, so they run everywhere."""
import subprocess
import sys

import pytest

from oprivview_replay import render

BUNDLED = "/app/ffmpeg/ffmpeg"
OWN = "/usr/bin/ffmpeg"


@pytest.fixture
def linux(monkeypatch):
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


def test_a_vaapi_job_names_its_device_and_others_do_not(linux, tmp_path, monkeypatch):
  import json
  from types import SimpleNamespace
  monkeypatch.setattr(render, "write_clip", lambda *a, **k: ([], 30, []))
  monkeypatch.setattr(render, "_tool", lambda name: BUNDLED)
  start = SimpleNamespace(frame=0)
  settings = {"camera": "road", "video_width": 1280}
  for how in (render.Encoding(BUNDLED, "h264_vaapi", "/dev/dri/renderD128"), render.Encoding(OWN, "libx264")):
    monkeypatch.setattr(render, "encoding", lambda ffmpeg, how=how: how)
    job = json.loads(render.prepare(None, tmp_path, start, start, settings, tmp_path / "o.mp4", progress=lambda t: None).read_text())
    assert (job["ffmpeg"], job["encoder"], job.get("encoder_device")) == (how.ffmpeg, how.encoder, how.device)
    assert ("encoder_device" in job) == (how.device is not None)
