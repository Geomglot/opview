import json

from oprivview_replay.camera import CameraPicker


def msg(kind, **data):
  return json.dumps({"type": kind, "data": data}, separators=(",", ":"))


def run(picker, *steps):
  out = []
  for kind, data in steps:
    picker.feed(msg(kind, **data))
    out.append(picker.letter)
  return out


def test_never_wide_outside_experimental_mode():
  p = CameraPicker("auto")
  assert run(p, ("carState", {"vEgo": 2.0}), ("selfdriveState", {"experimentalMode": False})) == ["R", "R"]


def test_wide_when_slow_in_experimental_mode_and_hysteresis():
  p = CameraPicker("auto")
  got = run(p,
            ("selfdriveState", {"experimentalMode": True}),
            ("carState", {"vEgo": 5.0}),    # slow: wide
            ("carState", {"vEgo": 12.0}),   # between 10 and 15: keep wide
            ("carState", {"vEgo": 16.0}),   # fast: road
            ("carState", {"vEgo": 12.0}),   # between: keep road
            ("carState", {"vEgo": 9.0}))    # slow again: wide
  assert got == ["W", "W", "W", "R", "R", "W"]  # at standstill, experimental mode starts on wide


def test_leaving_experimental_mode_goes_back_to_road():
  p = CameraPicker("auto")
  assert run(p, ("selfdriveState", {"experimentalMode": True}), ("carState", {"vEgo": 3.0}),
             ("selfdriveState", {"experimentalMode": False})) == ["W", "W", "R"]


def test_forced_modes_ignore_speed():
  assert run(CameraPicker("wide"), ("carState", {"vEgo": 30.0})) == ["W"]
  assert run(CameraPicker("road"), ("selfdriveState", {"experimentalMode": True}), ("carState", {"vEgo": 1.0})) == ["R", "R"]


def test_other_messages_change_nothing():
  p = CameraPicker("wide")
  p.feed(msg("modelV2", frameId=1))
  assert p.letter == "W"
