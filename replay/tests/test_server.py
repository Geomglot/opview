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
