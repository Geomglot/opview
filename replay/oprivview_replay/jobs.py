"""The steps shared by the command line and the server: find the drive, resolve a range, render it."""
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import render, ssh_source
from .logs import index_segment
from .timeline import FramePos, RangeError, RouteTimeline, resolve_range, zone_for


@dataclass
class Resolved:
  route: str
  segments: list[int]
  route_dir: Path
  timeline: RouteTimeline
  start: FramePos
  end: FramePos

  def describe(self) -> dict:
    tl = self.timeline
    seconds = (tl.wall_ms(self.end.segment, self.end.frame) - tl.wall_ms(self.start.segment, self.start.frame)) / 1000
    return {"zone": tl.zone.key, "start": tl.describe(self.start), "end": tl.describe(self.end),
            "start_segment": self.start.segment, "end_segment": self.end.segment, "seconds": round(seconds, 1)}


def resolve(host: str, cache: Path, route: str, start_segment: int | None = None, end_segment: int | None = None,
            start_time: str | None = None, end_time: str | None = None) -> Resolved:
  """raises RangeError for anything the user can fix: unknown route, no GPS, a time outside the drive"""
  segments = ssh_source.list_routes(host).get(route)
  if not segments:
    raise RangeError(f"{route} is not on the comma")
  ssh_source.fetch(host, route, segments, ("qlog.zst",), cache)
  route_dir = cache / route
  index = {s: index_segment(route_dir / str(s) / "qlog.zst") for s in segments}
  located = next((i for i in index.values() if i.lat is not None), None)
  if located is None:
    raise RangeError("this drive has no GPS position, so its time zone is unknown")
  timeline = RouteTimeline(index, zone_for(located.lat, located.lon))
  start, end = resolve_range(timeline, start_segment, end_segment, start_time, end_time)
  return Resolved(route, segments, route_dir, timeline, start, end)


def render_resolved(r: Resolved, host: str, cache: Path, settings: dict, output: Path, app: Path,
                    progress: Callable[[str], None] = print) -> None:
  needed = [s for s in r.segments if r.start.segment <= s <= r.end.segment]
  earlier = render.preroll_segment(r.timeline, r.start)
  progress("fetching logs and video")
  ssh_source.fetch(host, r.route, needed, ("rlog.zst", "fcamera.hevc"), cache)
  if earlier is not None:
    ssh_source.fetch(host, r.route, [earlier], ("rlog.zst",), cache)
  progress("rendering")
  render.run(r.timeline, r.route_dir, r.start, r.end, settings, output, app, progress)
