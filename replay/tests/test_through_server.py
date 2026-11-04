"""The comma reached through comma's own SSH server (comma prime), for when it is not on this network."""
import shlex
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from oprivview_replay import jobs, server, ssh_source
from oprivview_replay.settings import Settings
from oprivview_replay.sources import DeviceSource, SourceError

from test_sources import Fake, resolved

FULL = ("rlog.zst", "fcamera.hevc", "qlog.zst", "qcamera.ts")
DONGLE = "0123456789abcdef"


def test_the_settings_file_jumps_through_comma_s_server_with_the_comma_s_own_key(monkeypatch, tmp_path):
  key = tmp_path / "keys" / "id_ed25519"
  key.parent.mkdir()
  key.write_text("key")
  ssh_g = f"user comma\nidentityfile {key}\nidentityfile {tmp_path / 'keys' / 'id_rsa'}\n"  # the second does not exist
  monkeypatch.setattr(ssh_source.subprocess, "run", lambda args, **kw: SimpleNamespace(stdout=ssh_g) if args[:2] == ["ssh", "-G"] else None)
  folder = tmp_path / "through server"
  path = ssh_source.ThroughServer(DONGLE, folder).config()
  assert "\\" not in path, "forward slashes: Windows' ssh drops backslashes from the path it gives the second hop"
  text = Path(path).read_text()
  assert f"HostName comma-{DONGLE}" in text and f"ProxyJump comma-{DONGLE}@ssh.comma.ai:22" in text
  assert f'IdentityFile "{key.as_posix()}"' in text and "id_rsa" not in text and "IdentitiesOnly yes" in text
  assert f'UserKnownHostsFile "{(folder / "known_hosts").as_posix()}"' in text, "the user's own known_hosts is left alone"
  assert "BatchMode yes" in text and "StrictHostKeyChecking accept-new" in text


@pytest.fixture
def through(monkeypatch, tmp_path):
  monkeypatch.setattr(ssh_source, "comma_keys", lambda: [])
  return ssh_source.ThroughServer(DONGLE, tmp_path / "ts")


def test_commands_and_copies_through_comma_s_server_use_the_settings_file(monkeypatch, tmp_path, through):
  calls = []

  def run(args, **kw):
    calls.append((args, kw))
    return SimpleNamespace(stdout="5 x\n")

  monkeypatch.setattr(ssh_source.subprocess, "run", run)
  ssh_source.run(through, "true")
  assert calls[-1][0] == ["ssh", "-F", (tmp_path / "ts" / "ssh_config").as_posix(), "comma-via-server", "true"]
  monkeypatch.setattr(sys, "platform", "darwin")
  ssh_source.fetch(through, "r", [3], ("rlog.zst",), tmp_path)
  args = calls[-1][0]
  assert args[:5] == ["rsync", "-a", "--partial", "--timeout=30", "-e"]
  assert args[5] == f"ssh -F {shlex.quote((tmp_path / 'ts' / 'ssh_config').as_posix())}"  # rsync splits -e on spaces
  assert args[6] == "comma-via-server:/data/media/0/realdata/r--3/rlog.zst"


def test_a_cancelled_copy_through_the_server_is_stopped_part_way(tmp_path):
  class Stop(Exception):
    pass

  ticks = []

  def tick():
    ticks.append(1)
    if len(ticks) == 2:
      raise Stop()

  slow = [sys.executable, "-c", "import time; time.sleep(30)"]
  with pytest.raises(Stop):
    ssh_source._copy(slow, tick=tick)
  assert len(ticks) == 2  # about two seconds, not thirty


def test_through_the_server_only_when_the_comma_on_this_network_does_not_answer_and_after_connect():
  remote = Fake("the comma through comma's server", None, FULL)
  connect = Fake("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  away = jobs.Sources(Fake("device", None), connect, through_server=lambda: remote)
  away.listed()
  assert jobs.choose_files(resolved(connect), away, [0, 1], "auto") == (remote, "full")
  # Connect already has the full files: nothing goes over the car's connection
  uploaded = Fake("connect", {"r": [0, 1]}, FULL)
  away = jobs.Sources(Fake("device", None), uploaded, through_server=lambda: remote)
  away.listed()
  assert jobs.choose_files(resolved(uploaded), away, [0, 1], "auto") == (uploaded, "full")
  # the comma on this network answers: never through the server, even for files it does not list
  home = jobs.Sources(Fake("device", {"r": [0, 1]}, FULL), connect, through_server=lambda: pytest.fail("not wanted at home"))
  home.listed()
  assert jobs.choose_files(resolved(home.device), home, [0, 1], "auto")[0] is home.device


def test_through_the_server_a_drive_the_comma_has_deleted_is_missing_there(monkeypatch, through):
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/rlog.zst": 1, "r--0/fcamera.hevc": 2})
  remote = DeviceSource(through)
  assert remote.missing("r", [0], ("rlog.zst", "fcamera.hevc")) == []
  assert remote.missing("r", [0, 1], ("rlog.zst", "fcamera.hevc")) == ["rlog.zst", "fcamera.hevc"]
  assert DeviceSource("comma").missing("r", [0, 1], ("rlog.zst",)) == [], "on this network the comma is not asked"


def test_the_copy_through_the_server_counts_what_has_arrived(monkeypatch, tmp_path, through):
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/fcamera.hevc": 4_000_000})
  said = []

  def fetch(host, route, segments, files, cache, tick):
    (cache / "r" / "0").mkdir(parents=True)
    (cache / "r" / "0" / "fcamera.hevc").write_bytes(b"x" * 1_000_000)
    tick()

  monkeypatch.setattr(ssh_source, "fetch", fetch)
  DeviceSource(through).fetch("r", [0], ("fcamera.hevc",), tmp_path / "cache", progress=said.append)
  assert said == ["fetching fcamera.hevc from the comma through comma's server: 1 of 4 MB"]


def test_a_resumed_copy_counts_from_what_is_here_and_never_goes_backwards(monkeypatch, tmp_path, through):
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/fcamera.hevc": 4_000_000})
  folder = tmp_path / "r" / "0"
  folder.mkdir(parents=True)
  (folder / "fcamera.hevc").write_bytes(b"x" * 2_000_000)  # kept from a copy stopped part-way
  said = []

  def fetch(host, route, segments, files, cache, tick):
    tick()
    (folder / ".fcamera.hevc.Ab12Cd").write_bytes(b"x" * 3_000_000)  # rsync's new copy, beside the old part
    tick()
    (folder / ".fcamera.hevc.Ab12Cd").replace(folder / "fcamera.hevc")
    (folder / "fcamera.hevc").write_bytes(b"x" * 4_000_000)
    tick()

  monkeypatch.setattr(ssh_source, "fetch", fetch)
  DeviceSource(through).fetch("r", [0], ("fcamera.hevc",), tmp_path, progress=said.append)
  assert [line.rsplit(": ", 1)[1] for line in said] == ["2 of 4 MB", "3 of 4 MB", "4 of 4 MB"]


def test_a_copy_stopped_part_way_marks_its_file_and_connect_then_downloads_it_whole(monkeypatch, tmp_path, through):
  from oprivview_replay.sources import ConnectSource, incomplete_marker

  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/rlog.zst": 10, "r--0/fcamera.hevc": 6})
  cache = tmp_path / "cache"

  class Cancelled(Exception):
    pass

  def stopped(host, route, segments, files, c, tick):
    (c / "r" / "0").mkdir(parents=True)
    (c / "r" / "0" / "rlog.zst").write_bytes(b"part")  # rsync keeps a stopped copy under the file's own name
    (c / "r" / "0" / "fcamera.hevc").write_bytes(b"whole!")
    raise Cancelled()

  monkeypatch.setattr(ssh_source, "fetch", stopped)
  with pytest.raises(Cancelled):
    DeviceSource(through).fetch("r", [0], ("rlog.zst", "fcamera.hevc"), cache, progress=lambda t: None)
  log = cache / "r" / "0" / "rlog.zst"
  assert incomplete_marker(log).exists() and not incomplete_marker(cache / "r" / "0" / "fcamera.hevc").exists()

  # Connect, later: the marked file comes down again, the whole one is left alone
  connect = ConnectSource(tmp_path / "no-token")
  monkeypatch.setattr(connect, "_urls", lambda route: {"logs": {0: "https://x/rlog"}, "cameras": {0: "https://x/fcam"}})
  got = []

  class Body:
    def __init__(self, url):
      got.append(url)
      self.left = b"0123456789"

    def read(self, n):
      chunk, self.left = self.left, b""
      return chunk

    def __enter__(self):
      return self

    def __exit__(self, *a):
      return False

  monkeypatch.setattr("oprivview_replay.sources.urllib.request.urlopen", lambda url, **k: Body(url))
  connect.fetch("r", [0], ("rlog.zst", "fcamera.hevc"), cache)
  assert got == ["https://x/rlog"] and log.read_bytes() == b"0123456789" and not incomplete_marker(log).exists()


def test_a_copy_through_the_server_that_finishes_clears_the_marks(monkeypatch, tmp_path, through):
  from oprivview_replay.sources import incomplete_marker

  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {"r--0/rlog.zst": 4})
  log = tmp_path / "r" / "0" / "rlog.zst"
  log.parent.mkdir(parents=True)
  log.write_bytes(b"pa")
  incomplete_marker(log).touch()
  monkeypatch.setattr(ssh_source, "fetch", lambda host, route, segments, files, c, tick: log.write_bytes(b"part"))
  DeviceSource(through).fetch("r", [0], ("rlog.zst",), tmp_path)
  assert not incomplete_marker(log).exists()


@pytest.mark.parametrize("device, setting, allowed", [
  ({"dongle_id": DONGLE, "prime": True, "is_owner": True}, True, True),
  ({"dongle_id": DONGLE, "prime": False, "is_owner": True}, True, False),  # the server needs prime
  ({"dongle_id": DONGLE, "prime": True, "is_owner": False}, True, False),  # someone else's device
  ({"dongle_id": DONGLE, "prime": True, "is_owner": True}, False, False),  # turned off in App settings
])
def test_comma_s_server_is_used_only_for_the_user_s_own_prime_device_with_the_setting_on(tmp_path, device, setting, allowed):
  class Connect:
    public = False

    def available(self):
      return True

    def dongle(self):
      return DONGLE

    def devices(self):
      return [device]

    def use_device(self, d):
      pass

  settings = Settings(tmp_path / "settings.json")
  settings.update(via_server=setting)
  captured = {}
  original = jobs.Sources.__init__

  def keep(self, *a, **k):
    original(self, *a, **k)
    captured["sources"] = self

  try:
    jobs.Sources.__init__ = keep
    server.make_app(host="x", connect=Connect(), settings=settings, cache=tmp_path / "cache")
  finally:
    jobs.Sources.__init__ = original
  got = captured["sources"].through_server()
  assert (got is not None) == allowed
  if allowed:
    assert got.through_server and got.host.dongle == DONGLE


def test_the_setting_is_offered_and_saved(tmp_path):
  from fastapi.testclient import TestClient

  c = TestClient(server.make_app(host="x", connect=None, settings=Settings(tmp_path / "s.json")))
  assert c.get("/settings").json()["via_server"] is True
  assert c.put("/settings", json={"via_server": False}).json()["via_server"] is False


# step C: a copy through comma's server checks the comma's connection first

def _connect_answering(monkeypatch, result):
  from oprivview_replay.sources import ConnectSource

  c = ConnectSource(Path("no-token"))
  if isinstance(result, Exception):
    def athena(method, params=None, timeout=15):
      raise result
  else:
    def athena(method, params=None, timeout=15):
      assert method == "getMessage" and params["service"] == "deviceState"
      return {"deviceState": result}
  monkeypatch.setattr(c, "athena", athena)
  return c


def test_the_comma_says_what_connection_it_is_on(monkeypatch):
  assert _connect_answering(monkeypatch, {"networkType": "wifi", "networkMetered": False}).network() == {"kind": "Wi-Fi", "metered": False}
  assert _connect_answering(monkeypatch, {"networkType": "cell4G", "networkMetered": True}).network() == {"kind": "cellular", "metered": True}
  assert _connect_answering(monkeypatch, SourceError("timed out")).network() is None
  assert _connect_answering(monkeypatch, {"networkType": "wifi"}).network() is None  # no metered answer is no answer


class Remote(Fake):
  through_server = True
  host = "comma-via-server"

  def fetch(self, route, segments, names, cache, progress=None):
    self.fetched = getattr(self, "fetched", []) + [names]


class Connect(Fake):
  def fetch(self, route, segments, names, cache):
    self.fetched = getattr(self, "fetched", []) + [names]


def _render(monkeypatch, tmp_path, network, ask, detail="auto"):
  from oprivview_replay import render

  remote = Remote("the comma through comma's server", None, FULL)
  connect = Connect("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  monkeypatch.setattr(connect, "network", lambda: network, raising=False)
  sources = jobs.Sources(Fake("device", None), connect, through_server=lambda: remote)
  sources.listed()
  monkeypatch.setattr(render, "preroll_segment", lambda tl, start: None)
  monkeypatch.setattr(render, "wide_segments", lambda *a, **k: [])
  monkeypatch.setattr(render, "prepare", lambda *a, **k: tmp_path / "preview-job.json")
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {p: 44_000_000 for p in paths if "ecamera" not in p})
  r = jobs.Resolved("r", [0, 1], tmp_path, None, SimpleNamespace(segment=0), SimpleNamespace(segment=0), connect)
  said = []
  jobs.render_resolved(r, sources, tmp_path, {"detail": detail, "camera": "road"}, tmp_path / "x.mp4", tmp_path, said.append,
                       preview=True, ask=ask)
  return remote, connect, said


def test_on_an_unmetered_connection_it_copies_without_asking(monkeypatch, tmp_path):
  remote, connect, said = _render(monkeypatch, tmp_path, {"kind": "Wi-Fi", "metered": False}, ask=lambda q: pytest.fail("asked"))
  assert remote.fetched and not hasattr(connect, "fetched")


def test_on_a_metered_connection_it_asks_with_the_size_and_copies_if_told_to(monkeypatch, tmp_path):
  asked = []
  remote, connect, _ = _render(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, ask=lambda q: asked.append(q) or True)
  assert "on cellular, which it is set to treat as metered" in asked[0] and "about 88 MB" in asked[0]
  assert remote.fetched


def test_not_now_uses_what_connect_has(monkeypatch, tmp_path):
  remote, connect, _ = _render(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, ask=lambda q: False)
  assert not hasattr(remote, "fetched") and connect.fetched == [("qlog.zst", "qcamera.ts")]


def test_no_answer_from_the_comma_is_treated_as_metered(monkeypatch, tmp_path):
  asked = []
  _render(monkeypatch, tmp_path, None, ask=lambda q: asked.append(q) or False)
  assert asked and asked[0].startswith("The comma did not say whether its connection is metered.")


def test_not_now_with_full_detail_chosen_stops_and_says_how_to_go_on(monkeypatch, tmp_path):
  with pytest.raises(SourceError, match="Choose Automatic detail"):
    _render(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, ask=lambda q: False, detail="full")


def test_the_window_answers_the_job_s_question_and_cancel_ends_the_wait(monkeypatch, tmp_path):
  import threading
  import time

  from fastapi.testclient import TestClient

  from test_server import _resolved, _wait_for

  _resolved(monkeypatch, tmp_path)
  answers = []

  def fake_render(resolved, sources, cache, settings, output, app, progress, preview=False, started=None, ask=None, note=None):
    answers.append(ask("Copy now?"))
    answers.append(ask("Again?"))

  monkeypatch.setattr(jobs, "render_resolved", fake_render)
  c = TestClient(server.make_app(host="x", connect=None, output_dir=tmp_path))
  job = c.post("/jobs", json={"route": "r"}).json()
  assert _wait_for(c, job["id"], lambda j: j["question"])["question"] == "Copy now?"
  c.post(f"/jobs/{job['id']}/answer", json={"copy_now": True})
  assert _wait_for(c, job["id"], lambda j: j["question"] == "Again?")
  assert c.post(f"/jobs/{job['id']}/cancel").json()["state"] == "cancelled"
  time.sleep(1)
  assert answers == [True] and c.get(f"/jobs/{job['id']}").json()["question"] is None
  assert c.post(f"/jobs/{job['id']}/answer", json={"copy_now": True}).status_code == 409


def test_nothing_is_asked_when_everything_is_here_already(monkeypatch, tmp_path):
  for name in ("rlog.zst", "fcamera.hevc"):
    (tmp_path / "r" / "0").mkdir(parents=True, exist_ok=True)
    (tmp_path / "r" / "0" / name).write_bytes(b"x" * 10)
  monkeypatch.setattr(ssh_source, "remote_sizes", lambda host, paths: {p: 10 for p in paths})
  remote = Remote("the comma through comma's server", None, FULL)
  connect = Connect("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  monkeypatch.setattr(connect, "network", lambda: {"kind": "cellular", "metered": True}, raising=False)
  sources = jobs.Sources(Fake("device", None), connect, through_server=lambda: remote)
  r = jobs.Resolved("r", [0, 1], tmp_path, None, SimpleNamespace(segment=0), SimpleNamespace(segment=0), connect)
  assert None is jobs._may_copy_through_server(r, sources, remote, [0], None, {"camera": "road", "detail": "auto"}, tmp_path, lambda t: None,
                                       ask=lambda q: pytest.fail("asked about 0 MB"))


def test_a_command_through_the_server_that_cannot_connect_is_tried_once_more(monkeypatch, through):
  calls = []

  def run(args, **kw):
    calls.append(args)
    if len(calls) == 1:
      raise subprocess.CalledProcessError(255, args)
    return SimpleNamespace(stdout="ok")

  monkeypatch.setattr(ssh_source.subprocess, "run", run)
  monkeypatch.setattr("time.sleep", lambda s: None)
  assert ssh_source.run(through, "true") == "ok" and len(calls) == 2
  calls.clear()
  monkeypatch.setattr(ssh_source.subprocess, "run", lambda args, **kw: calls.append(args) or (_ for _ in ()).throw(subprocess.CalledProcessError(1, args)))
  with pytest.raises(subprocess.CalledProcessError):
    ssh_source.run(through, "false")
  assert len(calls) == 1, "a command that ran and failed is not repeated"


def test_with_full_detail_the_question_says_not_now_stops_and_the_error_matches_what_the_comma_said(monkeypatch, tmp_path):
  asked = []
  with pytest.raises(SourceError, match="not copied over a connection that may be metered"):
    _render(monkeypatch, tmp_path, None, ask=lambda q: asked.append(q) or False, detail="full")
  assert asked[0].endswith("Not now stops, because Full detail needs these files.")
  with pytest.raises(SourceError, match="not copied over the comma's metered connection"):
    _render(monkeypatch, tmp_path, {"kind": "cellular", "metered": True}, ask=lambda q: False, detail="full")


def test_the_drive_list_says_plainly_that_the_comma_is_away_when_connect_lists_the_drives(monkeypatch, tmp_path, capsys):
  from fastapi.testclient import TestClient

  class Listing:
    public = False

    def available(self):
      return True

    def use_device(self, d):
      pass

    def listing(self):
      return {}

  settings = Settings(tmp_path / "s.json")
  got = TestClient(server.make_app(host="192.0.2.1", connect=Listing(), settings=settings)).get("/routes").json()
  assert got["error"] == ("The comma is not on this network, so the drives are listed from comma Connect. "
                          "With comma prime, full detail comes from the comma through comma's server.")
  assert "192.0.2.1" in capsys.readouterr().err, "ssh's own words go to the log"
