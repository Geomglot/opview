from oprivview_replay.logs import Decoded, opview_params
from oprivview_replay.render import by_frame


def test_path_goes_with_the_frame_it_was_worked_out_from():
  decoded = Decoded(frame_ids=[100, 101, 102], frame_times=[1000, 2000, 3000],
                    messages=[[2900, 100, "late model for the first frame"], [1500, None, "speed"]])
  assert by_frame(decoded) == [(0, "late model for the first frame"), (1, "speed")]


def test_messages_on_one_frame_keep_their_order():
  decoded = Decoded(frame_ids=[1], frame_times=[1000], messages=[[10, None, "a"], [20, None, "b"], [30, None, "c"]])
  assert [text for _, text in by_frame(decoded)] == ["a", "b", "c"]


def test_settings_missing_from_the_log_fall_back_to_off():
  params = opview_params({"IsMetric": b"1", "SpeedLimitMode": b"2"})
  assert params["IsMetric"] is True
  assert params["SpeedLimitMode"] == 2
  assert params["RivianForceTorqueSteer"] is False
  assert params["SPCruiseSpeedOffset"] == 0


def test_panel_choices_match_the_names_the_app_checks():
  from pathlib import Path
  from oprivview_replay.params import PARAMS
  source = (Path(__file__).parents[2] / "lib/selfdrive/ui/onroad/detailed/detailed_layout.dart").read_text()
  panels = next(p for p in PARAMS if p.name == "collapsed_panels")
  assert all(f"collapsedPanels.contains('{name}')" in source for name in panels.choices)
