"""The steps shared by the command line and the server: find the drive, resolve a range, render it."""
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import render
from .logs import index_segment
from .sources import FULL_FILES as FULL, LOGS_FILES as LOGS, QUICK_FILES as QUICK, ConnectSource, DeviceSource, SourceError
from .timeline import FramePos, RangeError, RouteTimeline, resolve_range, zone_for


@dataclass
class Sources:
  device: DeviceSource
  connect: ConnectSource | None = None
  added: dict[str, ConnectSource] = field(default_factory=dict)  # someone else's public drives, by route
  # the comma through comma's server (comma prime), when it may be used: see choose_files
  through_server: Callable[[], DeviceSource | None] | None = None
  # whether the comma on this network answered the last listing; None before the first
  local_reachable: bool | None = None

  def listed(self) -> dict[str, tuple[object, list[int]]]:
    """route -> (source, segments). The comma wins over Connect for a route both have, since it has the full files."""
    out: dict[str, tuple[object, list[int]]] = {}
    if self.connect is not None and self.connect.available():
      try:
        out.update({r: (self.connect, s) for r, s in self.connect.routes().items()})
      except SourceError:
        pass
    try:
      out.update({r: (self.device, s) for r, s in self.device.routes().items()})
      self.local_reachable = True
    except SourceError:
      self.local_reachable = False
      if not out:
        raise
    for route, source in self.added.items():
      if route not in out:
        out[route] = (source, source.route_info(route)["segments"])
    return out


@dataclass
class Resolved:
  route: str
  segments: list[int]
  route_dir: Path
  timeline: RouteTimeline
  start: FramePos
  end: FramePos
  source: object

  def describe(self) -> dict:
    tl = self.timeline
    seconds = (tl.wall_ms(self.end.segment, self.end.frame) - tl.wall_ms(self.start.segment, self.start.frame)) / 1000
    return {"zone": tl.zone.key, "start": tl.describe(self.start), "end": tl.describe(self.end),
            "start_segment": self.start.segment, "end_segment": self.end.segment, "seconds": round(seconds, 1),
            "source": self.source.name}


def resolve(sources: Sources, cache: Path, route: str, start_segment: int | None = None, end_segment: int | None = None,
            start_time: str | None = None, end_time: str | None = None) -> Resolved:
  """raises RangeError for anything the user can fix: unknown route, no GPS, a time outside the drive"""
  try:
    found = sources.listed().get(route)
  except SourceError as e:
    raise RangeError(str(e))
  if not found:
    raise RangeError(f"{route} is on neither the comma nor comma Connect")
  source, segments = found
  try:
    source.fetch(route, segments, ("qlog.zst",), cache)
  except SourceError as e:
    raise RangeError(str(e))
  route_dir = cache / route
  index = {s: index_segment(route_dir / str(s) / "qlog.zst") for s in segments}
  located = next((i for i in index.values() if i.lat is not None), None)
  if located is None:
    raise RangeError("this drive has no GPS position, so its time zone is unknown")
  timeline = RouteTimeline(index, zone_for(located.lat, located.lon))
  start, end = resolve_range(timeline, start_segment, end_segment, start_time, end_time)
  return Resolved(route, segments, route_dir, timeline, start, end, source)


def choose_files(r: Resolved, sources: Sources, needed: list[int], detail: str) -> tuple[object, str]:
  """(where to get the files, and "full", "logs" or "quick") for what the user asked for and what exists"""
  candidates = [r.source]
  public = getattr(r.source, "public", False)  # someone else's drive: neither of this user's own sources has it
  for other in () if public else (sources.device, sources.connect):
    if other is None or other is r.source:
      continue
    try:
      # the comma only counts if it is reachable and has this drive; Connect is checked by its own file list
      if other is sources.device and sources.listed().get(r.route, (None, []))[0] is not other:
        continue
    except SourceError:
      continue
    candidates.append(other)
  # The comma through comma's server comes last, after Connect, which costs the car nothing. Only when the comma on this
  # network did not answer: never in its place while it does, nor after a copy from it failed part-way, so that a Wi-Fi
  # blip never moves a large copy onto the car's own internet connection.
  if not public and sources.through_server is not None and sources.local_reachable is False:
    remote = sources.through_server()
    if remote is not None:
      candidates.append(remote)
  if detail in ("auto", "full"):
    problems = []
    for source in candidates:
      try:
        gone = source.missing(r.route, needed, FULL)
      except SourceError as e:
        problems.append(str(e))
        continue
      if not gone:
        return source, "full"
      problems.append(f"{source.name} lacks {', '.join(gone)}")
    if detail == "full":
      raise SourceError("the full files are not available (" + "; ".join(problems) + "). Use quick detail instead.")
  for name, files in (("logs", LOGS), ("quick", QUICK)):
    if detail not in ("auto", name):
      continue
    for source in candidates:
      try:
        if not source.missing(r.route, needed, files):
          return source, name
      except SourceError:
        continue
  raise SourceError("neither the comma nor comma Connect has the files for this drive")


_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _fetching(route: str) -> threading.Lock:
  with _locks_guard:
    return _locks.setdefault(route, threading.Lock())


def render_resolved(r: Resolved, sources: Sources, cache: Path, settings: dict, output: Path, app: Path,
                    progress: Callable[[str], None] = print, preview: bool = False,
                    started: Callable[[object], None] | None = None) -> Path | None:
  """fetch what is needed and render, and return where the clip was saved (see render.run). With [preview] it stops after
  writing the job file, which it returns instead, so the window can play the drive itself rather than encoding it."""
  needed = [s for s in r.segments if r.start.segment <= s <= r.end.segment]
  earlier = render.preroll_segment(r.timeline, r.start)
  source, detail = choose_files(r, sources, needed + ([earlier] if earlier is not None else []), settings["detail"])
  log_name, video_name = render.LOGS[detail], render.VIDEOS[detail]

  def fetch(segments: list[int], names: tuple[str, ...]) -> None:
    if getattr(source, "through_server", False):  # slow: count what has arrived, and let Cancel stop it part-way
      source.fetch(r.route, segments, names, cache, progress=progress)
    else:
      source.fetch(r.route, segments, names, cache)

  # one copy of a drive at a time, so a preview and a render of it never fetch the same files twice over
  with _fetching(r.route):
    progress(f"fetching the {detail} files from {source.name}")
    fetch(needed, (log_name, video_name))
    if earlier is not None:
      fetch([earlier], (log_name,))
    wide = render.wide_segments(r.timeline, r.route_dir, r.start, r.end, settings["camera"], detail)
    if wide:
      progress("fetching wide camera video")
      fetch(wide, ("ecamera.hevc",))
  progress("preparing the drive")  # also where a job cancelled during a long fetch stops, before it writes anything
  if preview:
    return render.prepare(r.timeline, r.route_dir, r.start, r.end, settings, output, progress, detail, name="preview-job.json")
  progress(f"rendering ({detail} detail)")
  return render.run(r.timeline, r.route_dir, r.start, r.end, settings, output, app, progress, detail, started)
