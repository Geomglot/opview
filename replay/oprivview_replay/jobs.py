"""The steps shared by the command line and the server: find the drive, resolve a range, render it."""
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import render, ssh_source
from .logs import index_segment
from .meter import Meter, megabytes
from .sources import FULL_FILES as FULL, LOGS_FILES as LOGS, QUICK_FILES as QUICK, ConnectSource, DeviceSource, SourceError, incomplete_marker
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
  # asks the comma to upload (segment, name) files of a route to Connect, and says what it did; None when it does not
  request_upload: Callable[[str, list[tuple[int, str]]], str | None] | None = None

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


MANY_SEGMENTS = 10  # about 10 minutes of drive still to fetch: enough to take a while, so the user is asked first


def _may_fetch_many(r: Resolved, source, cache: Path, needed: list[int], earlier: int | None, names: tuple[str, str],
                    detail: str, settings: dict, ask: Callable[..., bool]) -> None:
  """Ask before fetching a long stretch of drive that is not on this computer yet, with its size when the source can
  say it. What is here already does not count: a range fetched before, or partly before a Cancel, is not asked about
  again for that part. Raises SourceError if the user says not to fetch."""
  def here(s: int, n: str) -> bool:
    f = cache / r.route / str(s) / n
    return f.exists() and not incomplete_marker(f).exists()

  files = [(s, n) for s in needed for n in names] + ([(earlier, names[0])] if earlier is not None else [])
  to_fetch = [(s, n) for s, n in files if not here(s, n)]
  segments = sorted({s for s, _ in to_fetch})
  if len(segments) < MANY_SEGMENTS:
    return
  sizes_of = getattr(source, "sizes", None)
  sizes = {}
  if sizes_of is not None:
    try:
      sizes = sizes_of(r.route, segments, names)
    except SourceError:
      pass
  known = [sizes[i] for i in to_fetch if i in sizes]
  amount = f", about {megabytes(sum(known) * len(to_fetch) / len(known))} MB," if known else ""
  wide = " The wide camera video may add as much again." if settings["camera"] != "road" and detail != "quick" else ""
  where = "comma Connect" if source.name == "connect" else "the comma" if source.name == "device" else source.name
  if not ask(f"This range needs {len(segments)} segments (about {len(segments)} minutes of drive) that are not on this "
             f"computer yet{amount} at {detail} detail from {where}.{wide} That can take a while.\n\n"
             "Fetching shows the time left as it goes, and you can cancel it at any point: what has arrived by then "
             "stays on this computer, so fetching this range again carries on from there.", "many"):
    raise SourceError("Not fetched. Choose a shorter range, or quick detail, to fetch less.")


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
    _may_fetch_many(r, source, cache, needed, earlier, (log_name, video_name), detail, settings, ask)

  def fetch(segments: list[int], names: tuple[str, ...], what: str) -> None:
    """with how much has come and how long the rest should take, about once a second; Cancel stops it part-way, and
    what has arrived stays here for the next time"""
    meter = Meter(what)

    def arrived(done: int, total: int) -> None:
      status = meter.update(done, total)
      if fetching is not None:
        fetching(status)
      progress(Meter.describe(status))

    progress(f"fetching {what}")
    try:
      source.fetch(r.route, segments, names, cache, progress=arrived)
    finally:
      if fetching is not None:
        fetching(None)

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
