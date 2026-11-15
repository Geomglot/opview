"""Model Controls Speed and the Acceleration Control lift reach a replay from the log, as they reach the app live."""
import json

import zstandard

from oprivview_replay import logs


def _rlog(tmp_path, build):
  ev = logs._log.Event.new_message()
  ev.logMonoTime = 1_000_000_000
  build(ev.init("longitudinalPlanSP"))
  path = tmp_path / "rlog.zst"
  path.write_bytes(zstandard.ZstdCompressor().compress(ev.to_bytes()))
  return path


def _plan(tmp_path, build):
  decoded = logs.decode_rlog(_rlog(tmp_path, build))
  return json.loads(decoded.messages[0][2])["data"]


def test_model_speed_off_and_the_lift_are_decoded(tmp_path):
  def build(plan):
    plan.modelSpeedOff = True
    plan.accelerationControlBoostRequested = 0.123456
  data = _plan(tmp_path, build)
  assert data["modelSpeedOff"] is True
  assert data["accelerationControlBoostRequested"] == 0.123


def test_a_log_without_them_reads_as_the_model_on(tmp_path):
  data = _plan(tmp_path, lambda plan: None)
  assert data["modelSpeedOff"] is False


def test_saved_decodes_from_before_are_not_reused():
  assert logs.DECODED_VERSION >= 2
