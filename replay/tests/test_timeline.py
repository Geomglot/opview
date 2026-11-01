from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from oprivview_replay.logs import SegmentIndex
from oprivview_replay.params import PARAMS
from oprivview_replay.ssh_source import parse_listing
from oprivview_replay.timeline import FramePos, RangeError, RouteTimeline, resolve_range

TORONTO = ZoneInfo("America/Toronto")


def timeline(start: datetime, count: int, first: int = 0) -> RouteTimeline:
  base = int(start.timestamp() * 1e9)
  return RouteTimeline({first + n: SegmentIndex(frames=1200, first_mono=base + n * 60 * 10**9, wall_offset_ns=0) for n in range(count)}, TORONTO)


MORNING = datetime(2026, 10, 31, 9, 18, 31, tzinfo=TORONTO)


def test_time_of_day_finds_the_frame():
  tl = timeline(MORNING, 13)
  assert tl.resolve_time("09:23:33") == FramePos(5, 40)


def test_time_with_fraction_of_a_second():
  assert timeline(MORNING, 13).resolve_time("09:18:31.500") == FramePos(0, 10)


def test_segment_range_covers_whole_segments():
  tl = timeline(MORNING, 13)
  assert resolve_range(tl, 5, 6, None, None) == (FramePos(5, 0), FramePos(6, 1199))


def test_each_end_can_use_a_different_form():
  tl = timeline(MORNING, 13)
  assert resolve_range(tl, 5, None, None, "09:25:00") == (FramePos(5, 0), tl.resolve_time("09:25:00"))


def test_no_range_means_the_whole_drive():
  tl = timeline(MORNING, 3)
  assert resolve_range(tl, None, None, None, None) == (FramePos(0, 0), FramePos(2, 1199))


def test_time_outside_the_drive_says_when_it_ran():
  with pytest.raises(RangeError, match="09:18:31 EDT"):
    timeline(MORNING, 13).resolve_time("14:00")


def test_end_before_start_is_refused():
  with pytest.raises(RangeError, match="after the start"):
    resolve_range(timeline(MORNING, 13), None, None, "09:25", "09:20")


def test_segment_and_time_for_the_same_end_is_refused():
  with pytest.raises(RangeError, match="not both"):
    resolve_range(timeline(MORNING, 13), 1, None, "09:20", None)


def test_missing_segment_says_what_exists():
  with pytest.raises(RangeError, match="segments 3 to 7"):
    timeline(MORNING, 5, first=3).resolve_segment(9, end=False)


def test_drive_past_midnight():
  tl = timeline(datetime(2026, 7, 1, 23, 58, 0, tzinfo=TORONTO), 5)
  assert tl.resolve_time("00:01:00") == FramePos(3, 0)
  assert tl.resolve_time("23:59:00") == FramePos(1, 0)


def test_repeated_hour_asks_for_an_offset():
  tl = timeline(datetime(2026, 11, 1, 1, 0, 0, fold=0, tzinfo=TORONTO), 150)
  with pytest.raises(RangeError, match="twice"):
    tl.resolve_time("01:30")


def test_repeated_hour_settled_by_offset():
  tl = timeline(datetime(2026, 11, 1, 1, 0, 0, fold=0, tzinfo=TORONTO), 150)
  assert tl.resolve_time("01:30-04:00") == FramePos(30, 0)
  assert tl.resolve_time("01:30-05:00") == FramePos(90, 0)


def test_bad_time_text():
  with pytest.raises(RangeError, match="not a time of day"):
    timeline(MORNING, 2).resolve_time("9am")


def test_listing_groups_segments_in_number_order():
  assert parse_listing("0000005a--f16da7af40--10\n0000005a--f16da7af40--9\nboot\ncrash\n00000059--5e374df67a--0\n") == {
    "00000059--5e374df67a": [0], "0000005a--f16da7af40": [9, 10]}


def test_view_is_a_choice_of_the_three_layouts():
  view = next(p for p in PARAMS if p.name == "view")
  assert view.choices == ("classic", "enhanced", "detailed") and view.default == "classic"
