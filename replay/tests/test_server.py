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
      return {"zone": "UTC"}

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
