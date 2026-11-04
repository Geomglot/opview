"""Asking the comma to put a drive's full files on comma Connect (wish 3, step B)."""
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from oprivview_replay import jobs, server
from oprivview_replay.settings import Settings
from oprivview_replay.sources import ConnectSource, SourceError
from oprivview_replay.uploads import STALE_S, UploadRequests

from test_sources import Fake
from test_through_server import FULL, Connect, Remote

ROUTE = "00000061--7aa7b765a1"


def _connect(monkeypatch, answer, posted=None, called=None):
  c = ConnectSource(Path("no-token"))
  monkeypatch.setattr(c, "dongle", lambda: "d")

  def post(path, body):
    (posted if posted is not None else []).append((path, body))
    return [{"url": f"https://blob/{p}?sig", "headers": {"x-ms-blob-type": "BlockBlob"}} for p in body["paths"]]

  def athena(method, params=None, timeout=15, expiry=None):
    (called if called is not None else []).append((method, params, expiry))
    return answer(params) if callable(answer) else answer

  monkeypatch.setattr(c, "_post", post)
  monkeypatch.setattr(c, "athena", athena)
  return c


def test_the_comma_is_asked_as_connect_s_website_asks_it(monkeypatch):
  posted, called = [], []
  c = _connect(monkeypatch, {"enqueued": 3, "items": []}, posted, called)
  got = c.request_upload(ROUTE, [(3, "rlog.zst"), (4, "fcamera.hevc")])
  assert got == {"offline": False, "missing": []}
  assert posted == [("/v1/d/upload_urls/", {"paths": [f"{ROUTE}--3/rlog.zst", f"{ROUTE}--3/rlog.bz2", f"{ROUTE}--4/fcamera.hevc"],
                                             "expiry_days": 7})]
  method, params, expiry = called[0]
  assert method == "uploadFilesToUrls" and expiry is not None
  sent = params["files_data"]
  assert [f["fn"] for f in sent] == [f"{ROUTE}--3/rlog.zst", f"{ROUTE}--3/rlog.bz2", f"{ROUTE}--4/fcamera.hevc"]
  assert all(f["allow_cellular"] is False and f["priority"] == 0 and f["headers"] == {"x-ms-blob-type": "BlockBlob"} for f in sent)
  assert sent[2]["url"] == f"https://blob/{ROUTE}--4/fcamera.hevc?sig"


def test_a_file_counts_as_gone_from_the_comma_only_if_every_name_for_it_failed(monkeypatch):
  c = _connect(monkeypatch, {"enqueued": 1, "failed": [f"{ROUTE}--3/rlog.bz2", f"{ROUTE}--4/fcamera.hevc"]})
  assert c.request_upload(ROUTE, [(3, "rlog.zst"), (4, "fcamera.hevc")])["missing"] == [(4, "fcamera.hevc")]


def test_an_offline_comma_gets_the_request_when_it_comes_back(monkeypatch):
  c = _connect(monkeypatch, "Device offline, message queued")
  assert c.request_upload(ROUTE, [(3, "rlog.zst")]) == {"offline": True, "missing": []}


def test_the_upload_queue_says_which_drive_segment_and_file(monkeypatch):
  c = _connect(monkeypatch, [{"url": f"https://commadata2.blob.core.windows.net/commadata2/d/{ROUTE}/3/fcamera.hevc?sig",
                              "progress": 0.42, "current": True}])
  assert c.upload_queue() == [{"route": ROUTE, "segment": 3, "file": "fcamera.hevc", "progress": 0.42, "current": True}]
  monkeypatch.setattr(c, "athena", lambda *a, **k: (_ for _ in ()).throw(SourceError("offline")))
  assert c.upload_queue() is None


def test_requests_are_remembered_until_stale(tmp_path):
  u = UploadRequests(tmp_path / "upload-requests.json")
  u.add(ROUTE, [(3, "rlog.zst")], offline=True, now=1000)
  u.add(ROUTE, [(4, "fcamera.hevc")], offline=False, now=2000)
  assert u.get(ROUTE)["files"] == [[3, "rlog.zst"], [4, "fcamera.hevc"]]
  assert u.asked_recently(ROUTE, [(3, "rlog.zst"), (4, "fcamera.hevc")], now=3000)
  assert not u.asked_recently(ROUTE, [(5, "rlog.zst")], now=3000)
  assert not u.asked_recently(ROUTE, [(3, "rlog.zst")], now=2000 + STALE_S + 1)
  u.drop(ROUTE)
  assert u.get(ROUTE) is None


# when jobs ask for it

def _job(monkeypatch, tmp_path, network, answer, detail="auto", local=None, public=False):
  from oprivview_replay import render, ssh_source

  remote = Remote("the comma through comma's server", None, FULL)
  connect = Connect("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  connect.public = public
  monkeypatch.setattr(connect, "network", lambda: network, raising=False)
  asked = []
  sources = jobs.Sources(Fake("device", local), connect, through_server=lambda: remote,
                         request_upload=lambda route, files: asked.append(files) or "Asked the comma.")
  sources.listed()
  monkeypatch.setattr(render, "preroll_segment", lambda tl, start: None)
  monkeypatch.setattr(render, "wide_segments", lambda *a, **k: [0])
  monkeypatch.setattr(render, "prepare", lambda *a, **k: tmp_path / "preview-job.json")
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {p: 1_000_000 for p in paths})
  r = jobs.Resolved("r", [0, 1], tmp_path, None, SimpleNamespace(segment=0), SimpleNamespace(segment=0), connect)
  notes = []
  jobs.render_resolved(r, sources, tmp_path, {"detail": detail, "camera": "auto"}, tmp_path / "x.mp4", tmp_path, lambda t: None,
                       preview=True, ask=lambda q: answer, note=notes.append)
  return asked, notes


def test_after_a_copy_through_the_server_the_same_files_are_asked_for(monkeypatch, tmp_path):
  asked, notes = _job(monkeypatch, tmp_path, {"kind": "Wi-Fi", "metered": False}, True)
  assert asked == [[(0, "rlog.zst"), (0, "fcamera.hevc"), (0, "ecamera.hevc")]] and notes == ["Asked the comma."]


def test_not_now_renders_from_connect_and_asks_for_the_full_files_for_next_time(monkeypatch, tmp_path):
  asked, _ = _job(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, False)
  assert asked == [[(0, "rlog.zst"), (0, "fcamera.hevc"), (0, "ecamera.hevc")]]


def test_at_home_and_for_someone_else_s_drive_nothing_is_asked(monkeypatch, tmp_path):
  asked, _ = _job(monkeypatch, tmp_path, None, True, local={"r": [0, 1]})
  assert asked == []
  asked, _ = _job(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, False, public=True)
  assert asked == []


def test_full_detail_that_cannot_be_had_asks_for_it_and_says_to_render_again(monkeypatch, tmp_path):
  with pytest.raises(SourceError, match="Asked the comma. Render again when the drive shows Full detail."):
    _job(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, False, detail="full")


# the server's side: the setting, what Connect already has, repeats, and the drive pane's status

class FakeConnect:
  public = False

  def __init__(self, has=(), queue=None, network=None, answer=None):
    self.has, self.queue, self.net, self.answer, self.requests = set(has), queue, network, answer, []

  def available(self):
    return True

  def use_device(self, d):
    pass

  def forget_route(self, route):
    pass

  def missing(self, route, segments, names):
    return [n for n in names if any((s, n) not in self.has for s in segments)]

  def request_upload(self, route, files):
    self.requests.append(files)
    return self.answer or {"offline": False, "missing": []}

  def upload_queue(self):
    return self.queue

  def network(self):
    return self.net


def _server(tmp_path, connect, keep=True):
  settings = Settings(tmp_path / "s.json")
  settings.update(keep_on_connect=keep)
  captured = {}
  original = jobs.Sources.__init__

  def keep_it(self, *a, **k):
    original(self, *a, **k)
    captured["sources"] = self

  jobs.Sources.__init__ = keep_it
  try:
    app = server.make_app(host="x", connect=connect, settings=settings, cache=tmp_path / "cache")
  finally:
    jobs.Sources.__init__ = original
  return TestClient(app), captured["sources"].request_upload


def test_only_what_connect_lacks_is_asked_for_and_not_twice_in_a_week(tmp_path):
  connect = FakeConnect(has={(0, "rlog.zst")})
  _, request = _server(tmp_path, connect)
  said = request(ROUTE, [(0, "rlog.zst"), (0, "fcamera.hevc")])
  assert connect.requests == [[(0, "fcamera.hevc")]] and said.startswith("Asked the comma to upload")
  assert request(ROUTE, [(0, "fcamera.hevc")]) == "The comma was already asked to upload the full files to comma Connect."
  assert len(connect.requests) == 1
  assert request(ROUTE, [(0, "rlog.zst")]) is None  # Connect has it


def test_with_keep_a_copy_off_nothing_is_asked(tmp_path):
  connect = FakeConnect()
  _, request = _server(tmp_path, connect, keep=False)
  assert request(ROUTE, [(0, "fcamera.hevc")]) is None and connect.requests == []


def test_the_message_says_when_the_comma_is_offline_or_no_longer_has_files(tmp_path):
  _, request = _server(tmp_path, FakeConnect(answer={"offline": True, "missing": []}))
  assert "when it is next online" in request(ROUTE, [(0, "fcamera.hevc")])
  _, request = _server(tmp_path / "2", FakeConnect(answer={"offline": False, "missing": [(0, "fcamera.hevc")]}))
  assert "no longer has the full files" in request(ROUTE, [(0, "fcamera.hevc")])


def test_the_drive_pane_hears_how_the_upload_is_going(tmp_path):
  connect = FakeConnect(queue=[{"route": ROUTE, "segment": 0, "file": "fcamera.hevc", "progress": 0.5, "current": True}])
  c, request = _server(tmp_path, connect)
  assert c.get(f"/uploads/{ROUTE}").json() == {"requested": False}
  request(ROUTE, [(0, "rlog.zst"), (0, "fcamera.hevc")])
  connect.has.add((0, "rlog.zst"))
  got = c.get(f"/uploads/{ROUTE}").json()
  assert (got["files"], got["uploaded"], got["done"], got["answered"]) == (2, 1, False, True)
  assert got["current"] == {"segment": 0, "file": "fcamera.hevc", "progress": 0.5}
  connect.queue = [{"route": ROUTE, "segment": 0, "file": "fcamera.hevc", "progress": 0, "current": False}]
  connect.net = {"kind": "cellular", "metered": True}
  assert c.get(f"/uploads/{ROUTE}").json()["metered"] is True
  connect.queue = None
  assert c.get(f"/uploads/{ROUTE}").json()["answered"] is False
  connect.has.add((0, "fcamera.hevc"))
  assert c.get(f"/uploads/{ROUTE}").json()["done"] is True
  assert c.get(f"/uploads/{ROUTE}").json() == {"requested": False}, "done is said once"
