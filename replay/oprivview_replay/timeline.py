"""Times of day and frames: where the drive was, and which frames a start and end mean."""
import bisect
import re
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .logs import SegmentIndex

FPS = 20
SEGMENT_MS = 60_000
# a comma can start a drive with a clock that looks set but is months out, and correct it a segment or two later
MAX_CLOCK_SLIP_MS = 5 * SEGMENT_MS
_TIME = re.compile(r"^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\s*([+-]\d{2}:?\d{2})?$")


class RangeError(ValueError):
  """a start or end that cannot be used; the message says why, for the person who typed it"""


def zone_for(lat: float, lon: float) -> ZoneInfo:
  from timezonefinder import TimezoneFinder
  name = TimezoneFinder().timezone_at(lat=lat, lng=lon)
  if name is None:
    raise RangeError(f"no time zone found at {lat:.3f}, {lon:.3f}")
  return ZoneInfo(name)


def settle_clocks(index: dict[int, SegmentIndex]) -> dict[int, SegmentIndex]:
  """A drive's segments run one after another, so a segment far from where the next one puts it has a wrong clock. The last
  segment is trusted, as the clock only ever gets corrected, and a wrong one takes its time from the segment after it."""
  out = dict(index)
  timed = sorted(s for s, i in index.items() if i.frames and i.wall_offset_ns is not None)
  for earlier, later in zip(reversed(timed[:-1]), reversed(timed[1:])):
    a, b = out[earlier], out[later]
    expected_ns = b.first_mono + b.wall_offset_ns - (later - earlier) * SEGMENT_MS * 10**6
    if abs(a.first_mono + a.wall_offset_ns - expected_ns) > MAX_CLOCK_SLIP_MS * 10**6:
      out[earlier] = replace(a, wall_offset_ns=expected_ns - a.first_mono)
  return out


@dataclass(frozen=True)
class FramePos:
  segment: int
  frame: int


class RouteTimeline:
  def __init__(self, index: dict[int, SegmentIndex], zone: ZoneInfo):
    self.segments = sorted(s for s, i in index.items() if i.frames and i.wall_offset_ns is not None)
    if not self.segments:
      raise RangeError("no segment of this route has both video frames and a set clock")
    self.index = settle_clocks(index)
    self.zone = zone
    self._starts_ms = [self.wall_ms(s, 0) for s in self.segments]

  def wall_ms(self, segment: int, frame: int) -> int:
    i = self.index[segment]
    return (i.first_mono + i.wall_offset_ns) // 1_000_000 + frame * 1000 // FPS

  def local(self, pos: FramePos) -> datetime:
    return datetime.fromtimestamp(self.wall_ms(pos.segment, pos.frame) / 1000, self.zone)

  def first(self) -> FramePos:
    return FramePos(self.segments[0], 0)

  def last(self) -> FramePos:
    s = self.segments[-1]
    return FramePos(s, self.index[s].frames - 1)

  def at_wall_ms(self, ms: int) -> FramePos:
    """the frame showing at [ms], or the nearest one if [ms] falls in a gap"""
    k = bisect.bisect_right(self._starts_ms, ms) - 1
    if k < 0:
      return self.first()
    s = self.segments[k]
    frame = (ms - self._starts_ms[k]) * FPS // 1000
    return FramePos(s, min(frame, self.index[s].frames - 1))

  def _candidates(self, text: str) -> list[int]:
    m = _TIME.match(text.strip())
    if not m:
      raise RangeError(f"'{text}' is not a time of day; use HH:MM or HH:MM:SS, optionally with a UTC offset like -04:00")
    hour, minute, second = int(m[1]), int(m[2]), int(m[3] or 0)
    fraction = int((m[4] or "0").ljust(3, "0"))
    if hour > 23 or minute > 59 or second > 59:
      raise RangeError(f"'{text}' is not a time of day")
    clock = time(hour, minute, second, fraction * 1000)
    first_day = self.local(self.first()).date()
    last_day = self.local(self.last()).date()
    days = [first_day + timedelta(n) for n in range((last_day - first_day).days + 1)]
    out = []
    for day in days:
      out += self._on_day(day, clock, m[5])
    return sorted(set(out))

  def _on_day(self, day: date, clock: time, offset: str | None) -> list[int]:
    if offset:
      digits = offset.replace(":", "")
      delta = timedelta(hours=int(digits[1:3]), minutes=int(digits[3:5]))
      tz = timezone(delta if digits[0] == "+" else -delta)
      return [int(datetime.combine(day, clock, tz).timestamp() * 1000)]
    # both readings of the time, which only differ in the hour repeated when clocks go back
    return [int(datetime.combine(day, clock, self.zone).replace(fold=f).timestamp() * 1000) for f in (0, 1)]

  def resolve_time(self, text: str) -> FramePos:
    first, last = self.first(), self.last()
    start, end = self.wall_ms(first.segment, first.frame), self.wall_ms(last.segment, last.frame)
    inside = [ms for ms in self._candidates(text) if start <= ms <= end + 1000]
    if not inside:
      raise RangeError(f"{text} is outside this drive, which ran {self._describe(self.first())} to {self._describe(self.last())}")
    if len(inside) > 1:
      a, b = (datetime.fromtimestamp(ms / 1000, self.zone) for ms in inside[:2])
      raise RangeError(f"{text} happened twice in this drive because the clocks went back. "
                       f"Add the offset: {text}{a.strftime('%z')} or {text}{b.strftime('%z')}")
    return self.at_wall_ms(inside[0])

  def resolve_segment(self, number: int, end: bool) -> FramePos:
    if number not in self.segments:
      raise RangeError(f"segment {number} is not available; this drive has segments {self.segments[0]} to {self.segments[-1]}")
    return FramePos(number, self.index[number].frames - 1 if end else 0)

  def _describe(self, pos: FramePos) -> str:
    return self.local(pos).strftime("%H:%M:%S %Z")

  def describe(self, pos: FramePos) -> str:
    return f"segment {pos.segment} frame {pos.frame} ({self.local(pos).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]} {self.local(pos).strftime('%Z')})"


def resolve_range(tl: RouteTimeline, start_segment: int | None, end_segment: int | None,
                  start_time: str | None, end_time: str | None) -> tuple[FramePos, FramePos]:
  if start_segment is not None and start_time:
    raise RangeError("give a start segment or a start time, not both")
  if end_segment is not None and end_time:
    raise RangeError("give an end segment or an end time, not both")
  start = tl.resolve_segment(start_segment, end=False) if start_segment is not None else (
    tl.resolve_time(start_time) if start_time else tl.first())
  end = tl.resolve_segment(end_segment, end=True) if end_segment is not None else (
    tl.resolve_time(end_time) if end_time else tl.last())
  if (end.segment, end.frame) <= (start.segment, start.frame):
    raise RangeError(f"the end ({tl.describe(end)}) must come after the start ({tl.describe(start)})")
  return start, end
