"""The steps shared by the command line and the server: find the drive, resolve a range, render it."""
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import render, ssh_source
from .logs import SegmentIndex, index_segment
from .meter import Meter, megabytes
from .sources import FULL_FILES as FULL, LOGS_FILES as LOGS, QUICK_FILES as QUICK, ConnectSource, DeviceSource, SourceError, incomplete_marker
from .timeline import FPS, SEGMENT_MS, FramePos, RangeError, RouteTimeline, resolve_range, zone_for


ASK_SEGMENTS_HOME = 30  # the comma on this network copies quickly, so it takes a long range to be worth asking about
ASK_SEGMENTS_AWAY = 5  # comma Connect, or the comma through comma's server


@dataclass
class Sources:
  device: DeviceSource
  connect: ConnectSource | None = None
  added: dict[str, ConnectSource] = field(default_factory=dict)  # someone else's public drives, by route
  # the comma through comma's server (comma prime), when it may be used: see choose_files
  through_server: Callable[[], DeviceSource | None] | None = None
  # whether the comma on this network answered the last listing; None before the first
  local_reachable: bool | None = None
  # asks the comma to upload (segment, name) files of a route to Connect, and says what it did; None when it does not
  request_upload: Callable[[str, list[tuple[int, str]]], str | None] | None = None
  # how many segments still to fetch make the user be asked first: (from the comma on this network, from anywhere else),
  # as the user set them in App settings; 0 for never
  ask_segments: Callable[[], tuple[int, int]] = lambda: (ASK_SEGMENTS_HOME, ASK_SEGMENTS_AWAY)

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


def logs_for(segments: list[int], start_segment: int | None, end_segment: int | None,
             start_time: str | None, end_time: str | None) -> list[int]:
  """Which segments' small logs a range needs. Given in segments: those in the range, the one before it (for the run-up
  to the first frame) and the drive's last (whose clock is the one trusted, should the range's own be wrong; see
  timeline.settle_clocks). Any time of day, or no range at all, needs the whole drive."""
  if start_time or end_time or (start_segment is None and end_segment is None) or not segments:
    return list(segments)
  low = segments[0] if start_segment is None else start_segment
  high = segments[-1] if end_segment is None else end_segment
  keep = {low, high, segments[-1]} | {s for s in segments if low - 1 <= s <= high}
  return [s for s in segments if s in keep]


def resolve(sources: Sources, cache: Path, route: str, start_segment: int | None = None, end_segment: int | None = None,
            start_time: str | None = None, end_time: str | None = None, progress: Callable[[str], None] | None = None,
            ask: Callable[..., bool] | None = None, fetching: Callable[[dict | None], None] | None = None) -> Resolved:
  """Raises RangeError for anything the user can fix: unknown route, no GPS, a time outside the drive. The times and
  positions come from the drive's small logs, which are fetched first if they are not here: for a long drive that takes
  a while, so it goes as a fetch in a job does (see render_resolved), with [ask], [progress] and [fetching].
  A range given in segments needs only the logs of those segments (see [logs_for]). For a time of day, the drive's last
  log says when the drive ran, and at about a minute a segment that says roughly which segments the time is in: those
  are read first, and more around them only if the time turns out not to be in them (see [near_the_times])."""
  progress = progress or (lambda text: None)
  progress("finding the drive")
  try:
    found = sources.listed().get(route)
  except SourceError as e:
    raise RangeError(str(e))
  if not found:
    raise RangeError(f"{route} is on neither the comma nor comma Connect")
  source, segments = found
  for number in (start_segment, end_segment):
    if number is not None and segments and number not in segments:
      raise RangeError(f"segment {number} is not available; this drive has segments {segments[0]} to {segments[-1]}")
  indexed: dict[int, SegmentIndex] = {}

  def fetch_logs(wanted: list[int]) -> dict[int, SegmentIndex]:
    todo = [s for s in wanted if s not in indexed]
    if todo:
      try:
        if ask is not None:
          many = _many_to_fetch(sources, source, cache, route, [(s, "qlog.zst") for s in todo])
          which = "every segment of the drive" if len(wanted) == len(segments) else "each segment in it"
          if many is not None and not ask(
              f"To check the range, the app reads the small log of {which}, and {many[0]} of them are not on this "
              f"computer yet{many[1]} from {_where(source)}. That can take a while.\n\n{_CAN_CANCEL}", "many"):
            raise SourceError("Not fetched.")
        _fetch(source, route, todo, ("qlog.zst",), cache, f"the drive's logs from {source.name}", progress, fetching)
      except SourceError as e:
        raise RangeError(str(e))
      indexed.update({s: index_segment(cache / route / str(s) / "qlog.zst") for s in todo})
    return {s: indexed[s] for s in wanted}

  def near_the_times() -> dict[int, SegmentIndex] | None:
    """The logs of the segments a range given as times of day is in, and of the drive's first and last segments. The last one's
    clock (the one trusted; see timeline.settle_clocks) puts every segment a minute apart before it, which says
    roughly where each time is; the segments there, with some to spare, are read, and if a time is not in them after
    all, more on that side, each time three times as many. None when the last log cannot say (no clock or no GPS in
    it), or when it comes to most of the drive anyway: the caller
    then reads the whole drive, which settles it."""
    first, last = segments[0], segments[-1]
    anchor = fetch_logs(sorted({first, last}))[last]  # the first too, so a time outside the drive is said with both ends
    if not anchor.frames or anchor.wall_offset_ns is None or anchor.lat is None:
      return None
    zone = zone_for(anchor.lat, anchor.lon)
    guess = RouteTimeline({s: SegmentIndex(frames=SEGMENT_MS * FPS // 1000, wall_offset_ns=anchor.wall_offset_ns,
                                           first_mono=anchor.first_mono - (last - s) * SEGMENT_MS * 10**6)
                           for s in segments}, zone)

    def near(text: str) -> int:
      """the segment [text] falls in by the reckoning; one before or after the drive by it, the first or last"""
      return guess.at_wall_ms(guess.candidates(text)[0]).segment

    low = start_segment if start_segment is not None else near(start_time) if start_time else segments[0]
    high = end_segment if end_segment is not None else near(end_time) if end_time else last
    times = [t for t in (start_time, end_time) if t]
    before, after = 2, 1  # one before the start for the run-up to its first frame, and one each way for the guess
    while True:
      window = [s for s in segments if min(low, high) - before <= s <= max(low, high) + after]
      if len(segments) == 1 or window[-1] >= segments[-2]:
        window = [s for s in segments if s >= window[0]]  # up to the last: one log more, and no gap before it
      if len(window) * 2 > len(segments):
        return None
      index = fetch_logs(sorted(set(window) | {first, last}))
      try:
        tl = RouteTimeline(index, zone)
      except RangeError:
        return None
      held = [s for s in tl.segments if s in window]
      if not held:
        return None
      lowest = tl.wall_ms(held[0], 0) + (SEGMENT_MS if held[0] != segments[0] else 0)
      highest = tl.wall_ms(held[-1], tl.index[held[-1]].frames - 1)
      wanted = [ms for t in times for ms in tl.candidates(t)]
      short_before = any(ms < lowest for ms in wanted) and window[0] != segments[0]
      short_after = any(ms > highest for ms in wanted) and window[-1] != last
      if not short_before and not short_after:
        return index
      before, after = before * 3 if short_before else before, after * 3 if short_after else after

  route_dir = cache / route
  index = near_the_times() if (start_time or end_time) and segments else None
  if index is None:
    index = fetch_logs(logs_for(segments, start_segment, end_segment, start_time, end_time))
  located = next((i for i in index.values() if i.lat is not None), None)
  if located is None and len(index) < len(segments):  # no GPS in the range: the rest of the drive may have it
    index = fetch_logs(segments)
    located = next((i for i in index.values() if i.lat is not None), None)
  if located is None:
    raise RangeError("this drive has no GPS position, so its time zone is unknown")
  timeline = RouteTimeline(index, zone_for(located.lat, located.lon))
  start, end = resolve_range(timeline, start_segment, end_segment, start_time, end_time)
  return Resolved(route, segments, route_dir, timeline, start, end, source)


def choose_files(r: Resolved, sources: Sources, needed: list[int], detail: str, allow_server: bool = True) -> tuple[object, str]:
  """(where to get the files, and "full", "logs" or "quick") for what the user asked for and what exists.
  [allow_server] False leaves out the comma through comma's server, as when the user said not to copy that way now."""
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
  if allow_server and not public and sources.through_server is not None and sources.local_reachable is False:
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


def _may_copy_through_server(r: Resolved, sources: Sources, source: DeviceSource, needed: list[int], earlier: int | None,
                             settings: dict, cache: Path, progress: Callable[[str], None],
                             ask: Callable[[str], bool] | None) -> str | None:
  """A copy through comma's server is plain SSH, so the comma cannot hold it back on a metered connection as it does its
  own uploads. Ask the comma what it is on: unmetered, copy; metered, or no answer, ask the user, with the size.
  Returns None to copy, or what the user declined to copy over: "the comma's metered connection", or "a connection that
  may be metered" when the comma did not say."""
  progress("checking the comma's connection")
  network = sources.connect.network() if sources.connect is not None else None
  if network is not None and not network["metered"]:
    return None
  if ask is None:  # nobody to ask, as on the command line
    return None
  files = [(s, n) for s in needed for n in FULL] + ([(earlier, FULL[0])] if earlier is not None else [])
  wide = [(s, "ecamera.hevc") for s in needed] if settings["camera"] != "road" else []
  try:
    sizes = ssh_source.remote_sizes(source.host, [f"{r.route}--{s}/{n}" for s, n in files + wide])
  except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):  # the size only makes the question clearer; it is still asked without one
    sizes = {}

  def to_copy(items: list[tuple[int, str]]) -> float:
    """MB still to come: what is already whole here is not copied again"""
    def here(s: int, n: str) -> int:
      f = cache / r.route / str(s) / n
      return f.stat().st_size if f.exists() else -1
    return sum(size for s, n in items if (size := sizes.get(f"{r.route}--{s}/{n}")) is not None and here(s, n) != size) / 1e6

  if sizes and not to_copy(files) and not to_copy(wide):
    return None  # everything is here already: the copy will send nothing, so there is nothing to ask
  why = (f"The comma is on {network['kind']}, which it is set to treat as metered." if network is not None
         else "The comma did not say whether its connection is metered.")
  amount = f"about {to_copy(files):.0f} MB of its data" if sizes else "its data"
  extra = f", and up to {to_copy(wide):.0f} MB more if the wide camera is used" if sizes and wide and to_copy(wide) else ""
  instead = ("Not now stops, because Full detail needs these files." if settings["detail"] == "full"
             else "Not now uses what comma Connect has, which is usually less detail.")
  if ask(f"{why} Copying full detail for this range through comma's server would use {amount}{extra}. Copy now?\n\n{instead}"):
    return None
  return "the comma's metered connection" if network is not None else "a connection that may be metered"


_CAN_CANCEL = ("Fetching shows the time left as it goes, and you can cancel it at any point: what has arrived by then "
               "stays on this computer, so fetching again carries on from there.")


def _here(cache: Path, route: str, s: int, n: str) -> bool:
  f = cache / route / str(s) / n
  return f.exists() and not incomplete_marker(f).exists()


def _where(source) -> str:
  return "comma Connect" if source.name == "connect" else "the comma" if source.name == "device" else source.name


def _many_to_fetch(sources: Sources, source, cache: Path, route: str, files: list[tuple[int, str]]) -> tuple[int, str] | None:
  """(how many segments, and ", about N MB," when the source can say) of [files] still to fetch, when that is as many as
  the user said to be asked about for this source; None when it is fewer. What is here already does not count: a range
  fetched before, or partly before a Cancel, is not asked about again for that part."""
  home, away = getattr(sources, "ask_segments", lambda: (ASK_SEGMENTS_HOME, ASK_SEGMENTS_AWAY))()
  limit = home if source.name == "device" else away
  to_fetch = [(s, n) for s, n in files if not _here(cache, route, s, n)]
  segments = sorted({s for s, _ in to_fetch})
  if limit <= 0 or len(segments) < limit:
    return None
  sizes = {}
  if (sizes_of := getattr(source, "sizes", None)) is not None:
    try:
      sizes = sizes_of(route, segments, tuple(sorted({n for _, n in to_fetch})))
    except SourceError:
      pass
  known = [sizes[i] for i in to_fetch if i in sizes]
  return len(segments), f", about {megabytes(sum(known) * len(to_fetch) / len(known))} MB," if known else ""


def _may_fetch_many(r: Resolved, sources: Sources, source, cache: Path, needed: list[int], earlier: int | None,
                    names: tuple[str, str], detail: str, settings: dict, ask: Callable[..., bool]) -> None:
  """Ask before fetching a long stretch of drive that is not on this computer yet. Raises SourceError if the user says
  not to fetch."""
  files = [(s, n) for s in needed for n in names] + ([(earlier, names[0])] if earlier is not None else [])
  many = _many_to_fetch(sources, source, cache, r.route, files)
  if many is None:
    return
  wide = " The wide camera video may add as much again." if settings["camera"] != "road" and detail != "quick" else ""
  if not ask(f"This range needs {many[0]} segments (about {many[0]} minutes of drive) that are not on this computer "
             f"yet{many[1]} at {detail} detail from {_where(source)}.{wide} That can take a while.\n\n{_CAN_CANCEL}", "many"):
    raise SourceError("Not fetched. Choose a shorter range, or quick detail, to fetch less.")


def _fetch(source, route: str, segments: list[int], names: tuple[str, ...], cache: Path, what: str,
           progress: Callable[[str], None], fetching: Callable[[dict | None], None] | None) -> None:
  """with how much has come and how long the rest should take, about once a second; Cancel stops it part-way, and what
  has arrived stays here for the next time"""
  meter = Meter(what)

  def arrived(done: int, total: int) -> None:
    status = meter.update(done, total)
    if fetching is not None:
      fetching(status)
    progress(Meter.describe(status))

  progress(f"fetching {what}")
  try:
    source.fetch(route, segments, names, cache, progress=arrived)
  finally:
    if fetching is not None:
      fetching(None)


def _render_again(said: str) -> str:
  return f"{said} Render again when the drive shows Full detail."


_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _fetching(route: str) -> threading.Lock:
  with _locks_guard:
    return _locks.setdefault(route, threading.Lock())


def render_resolved(r: Resolved, sources: Sources, cache: Path, settings: dict, output: Path, app: Path,
                    progress: Callable[[str], None] = print, preview: bool = False,
                    started: Callable[[object], None] | None = None,
                    ask: Callable[..., bool] | None = None,
                    note: Callable[[str], None] | None = None,
                    fetching: Callable[[dict | None], None] | None = None) -> Path | None:
  """fetch what is needed and render, and return where the clip was saved (see render.run). With [preview] it stops after
  writing the job file, which it returns instead, so the window can play the drive itself rather than encoding it.
  [ask] puts a yes-or-no question to the user: whether to copy over the comma's metered connection, or (with "many"
  after it) whether to fetch a long stretch of drive. [note] is told anything worth keeping in view after the job, such
  as an upload to Connect asked for. [fetching] is told how a fetch is going (see meter.Meter.update), and None after."""
  needed = [s for s in r.segments if r.start.segment <= s <= r.end.segment]
  earlier = render.preroll_segment(r.timeline, r.start)
  wanted = needed + ([earlier] if earlier is not None else [])

  def upload(files: list[tuple[int, str]]) -> str | None:
    """Ask the comma to put [files] on Connect, so they can be had later when it is offline. Only for this user's own
    drive with the comma away from this network: at home the comma is right there. Never fails the job."""
    if sources.request_upload is None or getattr(r.source, "public", False) or sources.local_reachable is not False:
      return None
    try:
      said = sources.request_upload(r.route, files)
    except SourceError as e:
      if note:
        note(f"Could not ask the comma to upload the full files to comma Connect: {e}")
      return None
    if said and note:
      note(said)
    return said

  # what full detail needs: the log and road camera of the range, the log before it for the preroll, and the wide camera
  # unless the camera is set to the road one (whether Automatic switches to it is only known from the logs)
  full_files = [(s, n) for s in needed for n in FULL] + ([(earlier, FULL[0])] if earlier is not None else [])
  wide_files = [(s, "ecamera.hevc") for s in needed] if settings["camera"] != "road" else []

  try:
    source, detail = choose_files(r, sources, wanted, settings["detail"])
  except SourceError as e:
    said = upload(full_files + wide_files) if settings["detail"] == "full" else None
    raise SourceError(f"{e} {_render_again(said)}" if said else str(e)) from None
  asked = []  # whether the metered question was put to the user

  def ask_metered(question: str) -> bool:
    asked.append(question)
    return ask(question)

  declined = (_may_copy_through_server(r, sources, source, needed, earlier, settings, cache, progress,
                                       ask_metered if ask is not None else None)
              if getattr(source, "through_server", False) else None)
  if declined is not None:
    if settings["detail"] == "full":
      said = upload(full_files + wide_files)
      raise SourceError(f"Full detail was not copied over {declined}. Choose Automatic detail to use "
                        "what comma Connect has now, or render again when the comma is on an unmetered connection."
                        + (f" {_render_again(said)}" if said else ""))
    source, detail = choose_files(r, sources, wanted, settings["detail"], allow_server=False)
  if detail != "full" and settings["detail"] == "auto":
    upload(full_files + wide_files)  # less detail now; the full files for next time
  log_name, video_name = render.LOGS[detail], render.VIDEOS[detail]
  # a copy the metered question has just given the size of, and the user said yes to, is not asked about twice
  if ask is not None and not (getattr(source, "through_server", False) and asked):
    _may_fetch_many(r, sources, source, cache, needed, earlier, (log_name, video_name), detail, settings, ask)

  def fetch(segments: list[int], names: tuple[str, ...], what: str) -> None:
    _fetch(source, r.route, segments, names, cache, what, progress, fetching)

  # one copy of a drive at a time, so a preview and a render of it never fetch the same files twice over
  with _fetching(r.route):
    fetch(needed, (log_name, video_name), f"the {detail} files from {source.name}")
    if earlier is not None:
      fetch([earlier], (log_name,), "the log before the range")
    wide = render.wide_segments(r.timeline, r.route_dir, r.start, r.end, settings["camera"], detail)
    if wide:
      fetch(wide, ("ecamera.hevc",), "wide camera video")
  if getattr(source, "through_server", False):
    # copied straight from the comma: now have it put the same files on Connect, after the copy so the two never compete
    # for the comma's connection
    progress("asking the comma to upload these files to comma Connect")
    upload(full_files + [(s, "ecamera.hevc") for s in wide])
  progress("preparing the drive")  # also where a job cancelled during a long fetch stops, before it writes anything
  if preview:
    return render.prepare(r.timeline, r.route_dir, r.start, r.end, settings, output, progress, detail, name="preview-job.json")
  progress(f"rendering ({detail} detail)")
  return render.run(r.timeline, r.route_dir, r.start, r.end, settings, output, app, progress, detail, started)
