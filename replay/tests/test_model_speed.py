"""The Legacy (Chill) speed setting and the Acceleration Control lift reach a replay from the log, as they reach the
app live."""
import json

import zstandard

from oprivview_replay import logs


def _rlog(tmp_path, build, params):
  init = logs._log.Event.new_message()
  init.logMonoTime = 500_000_000
  entries = init.init("initData").init("params").init("entries", len(params))
  for entry, (key, value) in zip(entries, params.items()):
    entry.key = key
    entry.value = value
  ev = logs._log.Event.new_message()
  ev.logMonoTime = 1_000_000_000
  build(ev.init("longitudinalPlanSP"))
  path = tmp_path / "rlog.zst"
  path.write_bytes(zstandard.ZstdCompressor().compress(init.to_bytes() + ev.to_bytes()))
  return path


def _plan(tmp_path, build, params=None):
  decoded = logs.decode_rlog(_rlog(tmp_path, build, {"LegacySpeedControl": b"1"} if params is None else params))
  return json.loads(decoded.messages[0][2])["data"]


def test_model_speed_off_and_the_lift_are_decoded(tmp_path):
  def build(plan):
    plan.modelSpeedOff = True
    plan.accelerationControlBoostRequested = 0.123456
  data = _plan(tmp_path, build)
  assert data["modelSpeedOff"] is True
  assert data["accelerationControlBoostRequested"] == 0.123


def test_the_model_on_is_sent_too_so_the_app_knows_the_branch_has_the_setting(tmp_path):
  assert _plan(tmp_path, lambda plan: None, {"LegacySpeedControl": b"0"})["modelSpeedOff"] is False


def test_drives_from_the_first_model_controls_speed_branch_count(tmp_path):
  assert _plan(tmp_path, lambda plan: None, {"ModelControlsSpeed": b"1"})["modelSpeedOff"] is False


def test_an_older_branch_sends_nothing_so_the_app_goes_by_experimental_mode(tmp_path):
  # live, an older comma's schema has no modelSpeedOff, so the app never gets it
  assert "modelSpeedOff" not in _plan(tmp_path, lambda plan: None, {"IsMetric": b"0"})


def test_saved_decodes_from_before_are_not_reused():
  assert logs.DECODED_VERSION >= 3
