"""The comma reached through comma's own SSH server (comma prime), for when it is not on this network."""
import shlex
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
