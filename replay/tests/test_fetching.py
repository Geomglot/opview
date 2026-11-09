"""Fetching a long range: the question before it, the time left while it goes, and Cancel keeping what has arrived."""
from types import SimpleNamespace

import pytest

from oprivview_replay import jobs, render, ssh_source
from oprivview_replay.meter import Meter, time_left
from oprivview_replay.sources import ConnectSource, DeviceSource, SourceError, incomplete_marker


class Clock:
  def __init__(self):
    self.now = 0.0

  def __call__(self):
    return self.now


def test_the_time_left_reads_plainly():
  assert time_left(None) == "working out the time left"
  assert time_left(2) == "almost done"
  assert time_left(42) == "about 40 s left"
  assert time_left(4 * 60 + 10) == "about 4 min left"
  assert time_left(2 * 3600 + 5 * 60) == "about 2 h 5 min left"


def test_the_time_left_comes_from_the_speed_once_enough_has_arrived():
  clock = Clock()
  meter = Meter("the full files from connect", clock)
  assert meter.update(0, 100_000_000)["seconds_left"] is None
  clock.now = 1
  assert meter.update(1_000_000, 100_000_000)["seconds_left"] is None, "too soon to say"
  clock.now = 4
  status = meter.update(4_000_000, 100_000_000)  # 1 MB a second
  assert status["seconds_left"] == 96
  assert Meter.describe(status) == "fetching the full files from connect: 4 of 100 MB, about 2 min left"


def test_before_anything_is_known_of_the_size_it_is_still_working_it_out():
  assert Meter("x", Clock()).update(0, 0)["seconds_left"] is None


def test_what_was_here_before_counts_as_done_but_not_towards_the_speed():
  clock = Clock()
  meter = Meter("x", clock)
  meter.update(50_000_000, 100_000_000)  # carried on from a cancelled fetch
  clock.now = 10
  assert meter.update(60_000_000, 100_000_000)["seconds_left"] == 40  # 1 MB a second, not 6


def test_the_speed_follows_the_last_half_minute():
  clock = Clock()
  meter = Meter("x", clock)
  for t in range(0, 61):  # fast for a minute, 2 MB a second
    clock.now = t
    meter.update(t * 2_000_000, 1_000_000_000)
  for t in range(61, 101):  # then slow, 0.5 MB a second
    clock.now = t
    status = meter.update(120_000_000 + (t - 60) * 500_000, 1_000_000_000)
  assert status["seconds_left"] == pytest.approx((1_000_000_000 - 140_000_000) / 500_000, rel=0.01)


class Body:
  def __init__(self, data: bytes, stop_after: int | None = None):
    self.left, self.stop_after, self.read_count = data, stop_after, 0

  def read(self, n):
    self.read_count += 1
    chunk, self.left = self.left[:n], self.left[n:]
    return chunk

  def __enter__(self):
    return self

  def __exit__(self, *a):
    return False


def _connect(monkeypatch, tmp_path, files: dict[str, bytes]):
  connect = ConnectSource(tmp_path / "no-token")
  monkeypatch.setattr(connect, "_urls", lambda route: {"cameras": {s: f"https://x/{s}" for s in range(len(files))}})
  bodies = {f"https://x/{s}": data for s, data in enumerate(files.values())}

  class Head:
    def __init__(self, n):
      self.headers = {"Content-Length": str(n)}

    def __enter__(self):
      return self

    def __exit__(self, *a):
      return False

  def opener(req, **k):
    if not isinstance(req, str) and req.get_method() == "HEAD":
      return Head(len(bodies[req.full_url]))
    return Body(bodies[req if isinstance(req, str) else req.full_url])

  monkeypatch.setattr("oprivview_replay.sources.urllib.request.urlopen", opener)
  ticks = iter(range(10, 10_000, 2))  # a second or more between reads, so every read is reported
  monkeypatch.setattr("oprivview_replay.sources.time.monotonic", lambda: next(ticks))
  return connect


def test_a_download_from_connect_says_how_much_has_come_out_of_how_much(monkeypatch, tmp_path):
  connect = _connect(monkeypatch, tmp_path, {"a": b"x" * (3 << 20), "b": b"y" * (1 << 20)})
  said = []
  connect.fetch("r", [0, 1], ("fcamera.hevc",), tmp_path, progress=lambda *a: said.append(a))
  total = 4 << 20
  assert said[0] == (0, total) and said[-1] == (total, total)
  assert all(t == total for _, t in said) and [d for d, _ in said] == sorted(d for d, _ in said)


def test_cancel_during_a_download_keeps_the_whole_files_and_drops_the_part(monkeypatch, tmp_path):
  connect = _connect(monkeypatch, tmp_path, {"a": b"x" * (1 << 20), "b": b"y" * (3 << 20)})

  class Cancelled(Exception):
    pass

  def progress(done, total):
    if done > (2 << 20):  # part-way into the second file
      raise Cancelled()

  with pytest.raises(Cancelled):
    connect.fetch("r", [0, 1], ("fcamera.hevc",), tmp_path, progress=progress)
  assert (tmp_path / "r" / "0" / "fcamera.hevc").stat().st_size == 1 << 20
  assert list((tmp_path / "r" / "1").iterdir()) == []

  said = []  # fetched again: only the file that did not finish comes down, and the count is of that
  connect.fetch("r", [0, 1], ("fcamera.hevc",), tmp_path, progress=lambda *a: said.append(a))
  assert said[-1] == (3 << 20, 3 << 20) and (tmp_path / "r" / "1" / "fcamera.hevc").stat().st_size == 3 << 20


def test_the_comma_on_this_network_counts_its_copy_and_marks_one_cancelled_part_way(monkeypatch, tmp_path):
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/fcamera.hevc": 4_000_000})
  folder = tmp_path / "r" / "0"
  said = []

  class Cancelled(Exception):
    pass

  def copy(host, route, segments, files, cache, tick):
    folder.mkdir(parents=True)
    (folder / "fcamera.hevc").write_bytes(b"x" * 1_000_000)  # rsync --partial keeps it under its own name
    tick()
    raise Cancelled()

  monkeypatch.setattr(ssh_source, "fetch", copy)
  with pytest.raises(Cancelled):
    DeviceSource("comma").fetch("r", [0], ("fcamera.hevc",), tmp_path, progress=lambda *a: said.append(a))
  assert said == [(1_000_000, 4_000_000)] and incomplete_marker(folder / "fcamera.hevc").exists()


def _resolved(tmp_path, segments):
  return jobs.Resolved("r", segments, tmp_path / "r", None, SimpleNamespace(segment=segments[0]),
                       SimpleNamespace(segment=segments[-1]), None)


class Source:
  name = "connect"

  def __init__(self, sizes=None):
    self._sizes = sizes or {}
    self.fetched = []

  def sizes(self, route, segments, names):
    return {(s, n): size for (s, n), size in self._sizes.items() if s in segments and n in names}

  def fetch(self, route, segments, names, cache, progress=None):
    self.fetched.append((segments, names))
    if progress:
      progress(0, 10)
      progress(10, 10)


def _run(monkeypatch, tmp_path, segments, ask, source=None, fetching=None, progress=None):
  source = source or Source()
  monkeypatch.setattr(jobs, "choose_files", lambda *a, **k: (source, "quick"))
  monkeypatch.setattr(render, "preroll_segment", lambda *a: None)
  monkeypatch.setattr(render, "wide_segments", lambda *a, **k: [])
  monkeypatch.setattr(render, "prepare", lambda *a, **k: tmp_path / "preview-job.json")
  sources = SimpleNamespace(request_upload=None, local_reachable=True)
  jobs.render_resolved(_resolved(tmp_path, segments), sources, tmp_path, {"detail": "quick", "camera": "road"},
                       tmp_path / "x.mp4", tmp_path, progress or (lambda t: None), preview=True, ask=ask, fetching=fetching)
  return source


def test_a_long_range_not_here_yet_is_asked_about_with_its_size(monkeypatch, tmp_path):
  asked = []
  sizes = {(s, n): 2_000_000 for s in range(12) for n in ("qlog.zst", "qcamera.ts")}
  source = _run(monkeypatch, tmp_path, list(range(12)), lambda q, kind="metered": asked.append((q, kind)) or True,
                Source(sizes))
  assert len(asked) == 1 and asked[0][1] == "many"
  assert "12 segments (about 12 minutes of drive)" in asked[0][0] and "about 48 MB" in asked[0][0]
  assert "comma Connect" in asked[0][0] and source.fetched


def test_saying_no_fetches_nothing(monkeypatch, tmp_path):
  source = Source()
  with pytest.raises(SourceError, match="Not fetched"):
    _run(monkeypatch, tmp_path, list(range(12)), lambda q, kind="metered": False, source)
  assert source.fetched == []


def test_a_short_range_or_one_already_here_is_not_asked_about(monkeypatch, tmp_path):
  never = lambda *a: pytest.fail("asked")  # noqa: E731
  _run(monkeypatch, tmp_path, list(range(4)), never)
  for s in range(3, 12):  # here from before, all but three segments
    for n in ("qlog.zst", "qcamera.ts"):
      (tmp_path / "r" / str(s)).mkdir(parents=True, exist_ok=True)
      (tmp_path / "r" / str(s) / n).write_bytes(b"x")
  _run(monkeypatch, tmp_path, list(range(12)), never)


def test_a_file_cancelled_part_way_still_counts_as_to_fetch(monkeypatch, tmp_path):
  for s in range(12):
    for n in ("qlog.zst", "qcamera.ts"):
      (tmp_path / "r" / str(s)).mkdir(parents=True, exist_ok=True)
      (tmp_path / "r" / str(s) / n).write_bytes(b"x")
      incomplete_marker(tmp_path / "r" / str(s) / n).touch()
  asked = []
  _run(monkeypatch, tmp_path, list(range(12)), lambda q, kind="metered": asked.append(kind) or True)
  assert asked == ["many"]


def test_the_job_is_told_how_the_fetch_goes_and_when_it_is_over(monkeypatch, tmp_path):
  told, said = [], []
  _run(monkeypatch, tmp_path, [0], None, fetching=told.append, progress=said.append)
  assert [t and (t["done"], t["total"]) for t in told] == [(0, 10), (10, 10), None]
  assert "fetching the quick files from connect: 0 of 0 MB, working out the time left" in said


def test_the_window_sees_the_fetch_and_its_bar_and_the_kind_of_question(monkeypatch, tmp_path):
  import threading
  import time

  from fastapi.testclient import TestClient

  from oprivview_replay import server

  class R:
    route_dir = tmp_path

    def describe(self):
      return {"zone": "UTC", "start_segment": 0, "end_segment": 11}

  monkeypatch.setattr(jobs, "resolve", lambda *a, **k: R())
  go = threading.Event()

  def fake_render(resolved, sources, cache, settings, output, app, progress, preview=False, started=None, ask=None,
                  note=None, fetching=None):
    assert ask("Fetch 12 segments?", "many")
    fetching({"what": "x", "done": 25, "total": 100, "seconds_left": 30})
    progress("fetching x: 0 of 0 MB, about 30 s left")
    go.wait(5)
    progress("still going")  # where Cancel stops it

  monkeypatch.setattr(jobs, "render_resolved", fake_render)
  c = TestClient(server.make_app(host="x", connect=None, output_dir=tmp_path))
  job = c.post("/jobs", json={"route": "r", "preview": True}).json()
  for _ in range(100):
    job = c.get(f"/jobs/{job['id']}").json()
    if job["question"]:
      break
    time.sleep(0.05)
  assert job["question_kind"] == "many"
  c.post(f"/jobs/{job['id']}/answer", json={"copy_now": True})
  for _ in range(100):
    job = c.get(f"/jobs/{job['id']}").json()
    if job["fetch"]:
      break
    time.sleep(0.05)
  assert job["fetch"]["seconds_left"] == 30 and job["progress"] == 0.25 and job["question_kind"] is None
  job = c.post(f"/jobs/{job['id']}/cancel").json()
  go.set()
  assert job["state"] == "cancelled" and job["fetch"] is None


def test_the_comma_on_this_network_is_asked_about_only_for_longer_ranges(monkeypatch, tmp_path):
  asked = []

  def ask(q, kind="metered"):
    asked.append(q)
    return True

  home = Source()
  home.name = "device"
  _run(monkeypatch, tmp_path, list(range(29)), ask, home)
  assert asked == [], "under 30 from the comma on this network"
  _run(monkeypatch, tmp_path / "b", list(range(30)), ask, home)
  assert len(asked) == 1 and "from the comma." in asked[0]


def _sources(home, away, source):
  return SimpleNamespace(ask_segments=lambda: (home, away), listed=lambda: {"r": (source, list(range(40)))},
                         request_upload=None, local_reachable=True)


def test_the_limits_are_the_user_s_and_0_never_asks(monkeypatch, tmp_path):
  from oprivview_replay import jobs as j

  away = Source()
  assert j._many_to_fetch(_sources(30, 8, away), away, tmp_path, "r", [(s, "qlog.zst") for s in range(7)]) is None
  assert j._many_to_fetch(_sources(30, 8, away), away, tmp_path, "r", [(s, "qlog.zst") for s in range(8)])[0] == 8
  assert j._many_to_fetch(_sources(0, 0, away), away, tmp_path, "r", [(s, "qlog.zst") for s in range(400)]) is None


def test_checking_a_range_asks_before_fetching_a_long_drive_s_logs_and_cancel_fetches_nothing(monkeypatch, tmp_path):
  from oprivview_replay import jobs as j
  from oprivview_replay.timeline import RangeError

  source = Source()
  asked = []
  # the drive's last log cannot say when it ran (no clock), so the whole drive is read for the time
  monkeypatch.setattr(j, "index_segment", lambda path: SimpleNamespace(frames=0, wall_offset_ns=None, lat=None))
  with pytest.raises(RangeError, match="Not fetched"):
    j.resolve(_sources(30, 5, source), tmp_path, "r", None, None, "09:00", ask=lambda q, kind="metered": asked.append((q, kind)) or False)
  assert source.fetched == [([0, 39], ("qlog.zst",))], "only the first and last logs, too few to ask about"
  assert asked[0][1] == "many" and "38 of them" in asked[0][0] and "every segment" in asked[0][0]


def test_checking_a_range_shows_the_fetch_of_the_drive_s_logs(monkeypatch, tmp_path):
  from oprivview_replay import jobs as j
  from oprivview_replay.timeline import RangeError

  told, said = [], []
  source = Source()
  monkeypatch.setattr(j, 'index_segment', lambda path: SimpleNamespace(frames=0, wall_offset_ns=None, lat=None))
  with pytest.raises(RangeError, match='no GPS position'):  # all this needs of the logs is that they were fetched
    j.resolve(_sources(30, 5, source), tmp_path, "r", None, None, "09:00", progress=said.append, ask=lambda *a: True, fetching=told.append)
  assert source.fetched == [([0, 39], ("qlog.zst",)), (list(range(1, 39)), ("qlog.zst",))]
  assert told[-1] is None and any(t and t["total"] == 10 for t in told)
  assert "fetching the drive's logs from connect" in said


def test_a_range_in_segments_needs_only_its_own_logs_with_the_one_before_and_the_drive_s_last():
  from oprivview_replay.jobs import logs_for

  drive = list(range(80))
  assert logs_for(drive, 2, 5, None, None) == [1, 2, 3, 4, 5, 79]
  assert logs_for(drive, 0, 3, None, None) == [0, 1, 2, 3, 79]
  assert logs_for(drive, 75, None, None, None) == [74, 75, 76, 77, 78, 79]
  assert logs_for(drive, None, 2, None, None) == [0, 1, 2, 79]
  assert logs_for(drive, 9, 4, None, None) == [4, 9, 79], "an end before the start is still said to be so"
  assert logs_for(drive, 2, None, None, "09:30") == drive, "a time of day can be anywhere in the drive"
  assert logs_for(drive, None, None, None, None) == drive


def test_checking_a_range_in_segments_fetches_only_its_logs_and_asks_by_those_alone(monkeypatch, tmp_path):
  from oprivview_replay import jobs as j
  from oprivview_replay.timeline import RangeError

  source = Source()
  asked = []
  monkeypatch.setattr(j, "index_segment", lambda path: SimpleNamespace(lat=None))
  with pytest.raises(RangeError, match="no GPS position"):
    j.resolve(_sources(30, 30, source), tmp_path / "a", "r", 2, 5, ask=lambda *a: asked.append(a) or True)
  # 6 segments are under the 30 to be asked about; with no GPS in the range the rest of the drive is read for it, and
  # that, at 40, is asked about
  assert len(asked) == 1 and "every segment of the drive" in asked[0][0]
  assert source.fetched == [([1, 2, 3, 4, 5, 39], ("qlog.zst",)), ([0] + list(range(6, 39)), ("qlog.zst",))], "not those read already"

  source = Source()
  with pytest.raises(RangeError, match="Not fetched"):
    j.resolve(_sources(30, 5, source), tmp_path / "b", "r", 2, 5, ask=lambda q, kind="metered": asked.append(q) or False)
  assert "6 of them" in asked[-1] and "each segment in it" in asked[-1] and source.fetched == []


def _drive_of(monkeypatch, segment_seconds: float, count: int = 80):
  """a drive in Toronto starting at 14:54:00 on 2026-11-06 whose segments are [segment_seconds] long (60 on a comma)"""
  from datetime import datetime
  from zoneinfo import ZoneInfo

  from oprivview_replay import jobs as j
  from oprivview_replay.logs import SegmentIndex

  base = int(datetime(2026, 11, 6, 14, 54, tzinfo=ZoneInfo("America/Toronto")).timestamp() * 1e9)
  monkeypatch.setattr(j, "index_segment", lambda path: SegmentIndex(
      frames=1200, first_mono=int(int(path.parent.name) * segment_seconds * 1e9), wall_offset_ns=base, lat=43.65, lon=-79.38))
  source = Source()
  sources = SimpleNamespace(ask_segments=lambda: (30, 5), listed=lambda: {"r": (source, list(range(count)))},
                            request_upload=None, local_reachable=True)
  return j, source, sources


def test_a_time_range_reads_the_segments_the_times_should_be_in_from_when_the_drive_ran(monkeypatch, tmp_path):
  j, source, sources = _drive_of(monkeypatch, 60)
  asked = []
  r = j.resolve(sources, tmp_path, "r", None, None, "15:00", "15:03", ask=lambda *a: asked.append(a) or True)
  assert (r.start.segment, r.end.segment) == (6, 9)
  # the first and last logs for when the drive ran, then the ones the times should be in with one to spare each way and one more
  # before for the run-up: 8 segments, which would be asked about only at 5 or more away from home
  assert source.fetched == [([0, 79], ("qlog.zst",)), ([4, 5, 6, 7, 8, 9, 10], ("qlog.zst",))]
  assert len(asked) == 1 and "each segment in it" in asked[0][0]


def test_when_the_times_are_not_where_a_minute_a_segment_puts_them_more_is_read_on_that_side(monkeypatch, tmp_path):
  # segments of 62 seconds put 15:00 nearly three minutes before where a minute a segment back from the last one says
  j, source, sources = _drive_of(monkeypatch, 62)
  r = j.resolve(sources, tmp_path, "r", None, None, "15:00", "15:03")
  assert (r.start.segment, r.end.segment) == (5, 8)
  assert len(source.fetched) > 2 and source.fetched[0] == ([0, 79], ("qlog.zst",))
  assert sum(len(f[0]) for f in source.fetched) < 40, "still well short of the whole drive"


def test_a_time_with_a_segment_at_the_other_end_and_one_outside_the_drive(monkeypatch, tmp_path):
  from oprivview_replay.timeline import RangeError

  j, source, sources = _drive_of(monkeypatch, 60)
  r = j.resolve(sources, tmp_path, "r", 3, None, None, "15:03")
  assert (r.start.segment, r.end.segment) == (3, 9)
  j, source, sources = _drive_of(monkeypatch, 60)
  with pytest.raises(RangeError, match="outside this drive, which ran 14:54:00"):
    j.resolve(sources, tmp_path / "b", "r", None, None, "18:00", None)
  assert sum(len(f[0]) for f in source.fetched) < 10, "said from the drive's end, and its start, without reading it all"


def test_a_segment_the_drive_does_not_have_is_said_before_anything_is_fetched(tmp_path):
  from oprivview_replay import jobs as j
  from oprivview_replay.timeline import RangeError

  source = Source()
  with pytest.raises(RangeError, match="segment 45 is not available; this drive has segments 0 to 39"):
    j.resolve(_sources(30, 5, source), tmp_path, "r", 2, 45)
  assert source.fetched == []


def _job(monkeypatch, tmp_path, resolve, body):
  import time

  from fastapi.testclient import TestClient

  from oprivview_replay import server

  monkeypatch.setattr(jobs, "resolve", resolve)
  monkeypatch.setattr(jobs, "render_resolved", lambda *a, **k: pytest.fail("rendered"))
  c = TestClient(server.make_app(host="x", connect=None, output_dir=tmp_path))
  job = c.post("/jobs", json={"route": "r", **body}).json()
  for _ in range(100):
    job = c.get(f"/jobs/{job['id']}").json()
    if job["state"] != "running":
      return job
    time.sleep(0.05)
  raise AssertionError(job)


def test_a_range_that_cannot_be_found_ends_the_job_as_failed(monkeypatch, tmp_path):
  from oprivview_replay.timeline import RangeError

  def resolve(*a, **k):
    raise RangeError("segment 99 is not in this drive")

  job = _job(monkeypatch, tmp_path, resolve, {})
  assert job["state"] == "failed" and job["error"] == "segment 99 is not in this drive"


def test_a_check_job_ends_with_the_range_and_renders_nothing(monkeypatch, tmp_path):
  class R:
    route_dir = tmp_path

    def describe(self):
      return {"zone": "UTC", "start": "a", "end": "b", "seconds": 60.0, "start_segment": 0, "end_segment": 0}

  job = _job(monkeypatch, tmp_path, lambda *a, **k: R(), {"check": True})
  assert job["state"] == "done" and job["check"] is True and job["range"]["seconds"] == 60.0


def test_the_limits_are_saved_settings(tmp_path):
  from fastapi.testclient import TestClient

  from oprivview_replay import server
  from oprivview_replay.settings import Settings

  c = TestClient(server.make_app(host="x", connect=None, settings=Settings(tmp_path / "s.json")))
  got = c.get("/settings").json()
  assert (got["ask_segments_home"], got["ask_segments_away"]) == (30, 5)
  assert c.put("/settings", json={"ask_segments_away": 12}).json()["ask_segments_away"] == 12
  assert Settings(tmp_path / "s.json")["ask_segments_away"] == 12
  assert c.put("/settings", json={"ask_segments_home": -1}).status_code == 422
