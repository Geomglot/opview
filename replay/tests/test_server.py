import sys

import pytest
from fastapi.testclient import TestClient

from oprivview_replay import params, server


def client():
  return TestClient(server.make_app(host="nonexistent-host-for-test", connect=None))


def test_params_list_matches_the_single_source():
  got = client().get("/params").json()
  assert [p["name"] for p in got] == [p.name for p in params.PARAMS]
  bar = next(p for p in got if p["name"] == "bar" or p["name"] == "bottom_bar")
  assert bar["choices"] == ["torque", "laneCentering", "auto", "off"]


def test_settings_defaults_and_validation():
  s = params.settings_from_dict({"view": "detailed", "collapsed_panels": ["lead"], "width": "1280"})
  assert s["view"] == "detailed" and s["width"] == 1280 and s["bottom_bar"] is None
  for bad in ({"view": "fancy"}, {"nope": 1}, {"collapsed_panels": ["x"]}):
    try:
      params.settings_from_dict(bad)
    except ValueError:
      continue
    raise AssertionError(bad)


def test_unreachable_comma_is_reported_not_raised():
  got = client().get("/routes").json()
  assert got["online"] is False and got["routes"] == []


def test_bad_option_is_a_422():
  r = client().post("/jobs", json={"route": "0000005a--f16da7af40", "options": {"view": "fancy"}})
  assert r.status_code == 422


def test_preview_job_returns_the_job_file_and_makes_no_mp4(monkeypatch, tmp_path):
  import time
  from pathlib import Path

  from oprivview_replay import jobs

  class R:
    def describe(self):
      return {"zone": "UTC", "start_segment": 2, "end_segment": 3}

  monkeypatch.setattr(jobs, "resolve", lambda *a, **k: R())
  seen = {}

  def fake_render(resolved, sources, cache, settings, output, app, progress, preview=False, started=None):
    seen["preview"], seen["output"] = preview, output
    return tmp_path / "preview-job.json" if preview else None

  monkeypatch.setattr(jobs, "render_resolved", fake_render)
  c = TestClient(server.make_app(host="x", connect=None, output_dir=tmp_path / "movies"))
  job = c.post("/jobs", json={"route": "0000005a--f16da7af40", "preview": True}).json()
  for _ in range(50):
    job = c.get(f"/jobs/{job['id']}").json()
    if job["state"] != "running":
      break
    time.sleep(0.05)
  assert job["state"] == "done" and job["preview"] is True and job["job_file"] == str(tmp_path / "preview-job.json")
  assert seen["preview"] is True and not (tmp_path / "movies").exists()


def test_default_output_says_which_part_and_never_replaces_a_clip(tmp_path):
  one = {"start_segment": 5, "end_segment": 5}
  first = server.default_output(tmp_path, one, "r")
  assert first.name == "r--seg5.mp4"
  first.write_bytes(b"x")
  assert server.default_output(tmp_path, one, "r").name == "r--seg5 (2).mp4"
  assert server.default_output(tmp_path, {"start_segment": 3, "end_segment": 4}, "r").name == "r--seg3-4.mp4"


def test_a_typed_output_path_may_use_a_tilde_and_leave_off_the_extension():
  from pathlib import Path
  assert server._chosen_output("~/clips/run") == Path.home() / "clips" / "run.mp4"


def _resolved(monkeypatch):
  from oprivview_replay import jobs

  class R:
    def describe(self):
      return {"zone": "UTC", "start_segment": 2, "end_segment": 3}

  monkeypatch.setattr(jobs, "resolve", lambda *a, **k: R())


def test_cancel_stops_a_job_and_it_stays_cancelled(monkeypatch, tmp_path):
  import threading
  import time

  from oprivview_replay import jobs

  _resolved(monkeypatch)
  entered, go = threading.Event(), threading.Event()
  killed = []

  class Renderer:
    def kill(self):
      killed.append(True)
      go.set()

  def fake_render(resolved, sources, cache, settings, output, app, progress, preview=False, started=None):
    started(Renderer())
    entered.set()
    go.wait(5)
    progress("frame 20 of 100 after 1 s")

  monkeypatch.setattr(jobs, "render_resolved", fake_render)
  c = TestClient(server.make_app(host="x", connect=None, output_dir=tmp_path))
  job = c.post("/jobs", json={"route": "r"}).json()
  assert entered.wait(5)
  assert c.post(f"/jobs/{job['id']}/cancel").json()["state"] == "cancelled"
  time.sleep(0.1)
  assert c.get(f"/jobs/{job['id']}").json()["state"] == "cancelled" and killed


def _fake_renderer(tmp_path, code: int = 0):
  """a renderer that writes something to the part file named in $PART and exits with [code]"""
  if sys.platform == "win32":  # Windows cannot run a #! script; a .cmd file is one it starts directly
    app = tmp_path / "renderer.cmd"
    app.write_text(f'@echo clip> "%PART%"\r\n@exit /b {code}\r\n')
    return app
  app = tmp_path / "renderer"
  app.write_text(f'#!/bin/sh\necho clip > "$PART"; exit {code}\n')
  app.chmod(0o755)
  return app


def _run_render(monkeypatch, tmp_path, app, frames_written):
  import json

  from oprivview_replay import render

  output = tmp_path / "clip.mp4"
  job = tmp_path / "job.json"
  job.write_text(json.dumps({"frame_count": 100}))

  def prepare(tl, route_dir, start, end, settings, out, progress, detail):
    assert out == render.part_file(output)
    return job

  monkeypatch.setattr(render, "prepare", prepare)
  monkeypatch.setattr(render, "video_frames", lambda path: frames_written)
  monkeypatch.setenv("PART", str(render.part_file(output)))
  render.run(None, tmp_path, None, None, {}, output, app, lambda t: None)
  return output


def test_a_finished_render_appears_under_its_name_with_no_part_file_left(monkeypatch, tmp_path):
  output = _run_render(monkeypatch, tmp_path, _fake_renderer(tmp_path), 100)
  assert output.exists() and list(tmp_path.glob("*.part.*")) == []


def test_a_short_render_is_a_failure_and_leaves_no_clip(monkeypatch, tmp_path):
  with pytest.raises(RuntimeError, match="30 of 100"):
    _run_render(monkeypatch, tmp_path, _fake_renderer(tmp_path), 30)
  assert not (tmp_path / "clip.mp4").exists() and list(tmp_path.glob("*.part.*")) == []


def test_a_renderer_that_dies_is_a_failure_and_leaves_no_clip(monkeypatch, tmp_path):
  import subprocess

  with pytest.raises(subprocess.CalledProcessError):
    _run_render(monkeypatch, tmp_path, _fake_renderer(tmp_path, 3), 100)
  assert not (tmp_path / "clip.mp4").exists() and list(tmp_path.glob("*.part.*")) == []


def test_a_job_cancelled_while_fetching_writes_nothing(monkeypatch, tmp_path):
  from types import SimpleNamespace

  from oprivview_replay import jobs, render

  monkeypatch.setattr(jobs, "choose_files", lambda *a: (SimpleNamespace(name="device", fetch=lambda *a: None), "full"))
  monkeypatch.setattr(render, "preroll_segment", lambda *a: None)
  monkeypatch.setattr(render, "wide_segments", lambda *a: [])
  monkeypatch.setattr(render, "prepare", lambda *a, **k: pytest.fail("a cancelled job wrote its files"))
  r = SimpleNamespace(segments=[0], start=SimpleNamespace(segment=0), end=SimpleNamespace(segment=0), timeline=None, route="r", route_dir=tmp_path)

  def stopped_after_fetch(text):
    if text == "preparing the drive":
      raise server.Cancelled()

  with pytest.raises(server.Cancelled):
    jobs.render_resolved(r, None, tmp_path, {"detail": "full", "camera": "road"}, tmp_path / "c.mp4", tmp_path, stopped_after_fetch, preview=True)


def _routes_with_connect(tmp_path, lat, lon):
  class Connect:
    def available(self):
      return True

    def listing(self):
      return {"r": {"segments": [0], "start_ms": 1793000000000, "end_ms": 1793000060000, "lat": lat, "lon": lon, "km": 1.0,
                  "start": (lat, lon), "end": (lat, lon)}}

  c = TestClient(server.make_app(host="nothing.invalid", connect=Connect(), cache=tmp_path, output_dir=tmp_path))
  return c.get("/routes").json()["routes"][0]


def test_a_drive_with_no_position_shows_the_mac_time_and_never_gmt(tmp_path):
  row = _routes_with_connect(tmp_path, 0, 0)
  assert row["local_start"].endswith("(Mac time)") and "GMT" not in row["local_start"].replace("(Mac time)", "")


def test_a_drive_with_a_position_shows_its_own_zone(tmp_path):
  assert _routes_with_connect(tmp_path, 43.7, -79.4)["local_start"].endswith(("EST", "EDT"))
