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
  _run(monkeypatch, tmp_path, list(range(9)), never)
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
