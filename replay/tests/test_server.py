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

  def fake_render(resolved, sources, cache, settings, output, app, progress, preview=False):
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
