import base64
import json
import stat
import time

import pytest
from fastapi.testclient import TestClient

from oprivview_replay import admin, places, render, server
from oprivview_replay.settings import Settings
from oprivview_replay.sources import ConnectSource, SourceError, parse_drive_ref


def test_a_town_is_found_for_a_position_and_none_for_open_water():
  assert places.nearest_town(40.5853, -105.0844) == "Fort Collins"
  assert places.nearest_town(30.0, -40.0) is None


def test_no_position_names_no_town_and_connects_zero_is_no_position():
  assert places.nearest_town(None, None) is None and places.nearest_town(0, 0) is None


def test_a_journey_names_both_ends_or_one_town_if_it_stayed_there():
  assert places.journey((40.585, -105.084), (40.397, -105.075)) == "Fort Collins to Loveland"
  assert places.journey((40.585, -105.084), (40.586, -105.085)) == "Fort Collins"
  assert places.journey((None, None), (40.585, -105.084)) == "Fort Collins"


@pytest.mark.parametrize("text", ["https://connect.comma.ai/0123456789abcdef/00000029--cc74b6e85b", "0123456789abcdef/00000029--cc74b6e85b",
                                  "0123456789abcdef|00000029--cc74b6e85b", "https://connect.comma.ai/0123456789abcdef/00000029--cc74b6e85b/2/5"])
def test_every_way_of_naming_a_drive_is_understood(text):
  assert parse_drive_ref(text) == ("0123456789abcdef", "00000029--cc74b6e85b")


def test_a_device_id_alone_means_all_of_its_public_drives():
  assert parse_drive_ref(" 0123456789abcdef ") == ("0123456789abcdef", None)


def test_nonsense_is_refused_with_a_reason():
  with pytest.raises(SourceError, match="device id"):
    parse_drive_ref("my drive")


def test_a_bare_address_gets_the_comma_user_and_a_name_is_left_alone():
  assert admin.host_for("192.168.4.38") == "comma@192.168.4.38"
  assert admin.host_for("comma") == "comma" and admin.host_for("me@10.0.0.2") == "me@10.0.0.2"


def test_networks_come_from_this_macs_addresses_without_loopback_or_link_local():
  text = "lo0: inet 127.0.0.1 netmask\nen0: inet 192.168.4.20 netmask\nen5: inet 169.254.7.7 netmask\nen1: inet 192.168.4.21\nen2: inet 10.0.1.5\n"
  assert admin.local_prefixes(text) == ["192.168.4", "10.0.1"]


def test_only_a_machine_that_answers_with_a_comma_id_counts_as_a_comma(monkeypatch):
  monkeypatch.setattr(admin, "_ssh_open", lambda a: a in ("10.0.0.5", "10.0.0.9"))
  monkeypatch.setattr(admin.ssh_source, "run", lambda host, cmd: "0123456789abcdef\n" if host.endswith(".9") else "not one")
  found = admin.find_commas(["10.0.0"])
  assert found == [{"address": "10.0.0.9", "comma": True, "dongle": "0123456789abcdef"}, {"address": "10.0.0.5", "comma": False, "dongle": None}]


def _token(expires: float) -> str:
  body = base64.urlsafe_b64encode(json.dumps({"exp": int(expires)}).encode()).decode().rstrip("=")
  return f"head.{body}.sig"


def test_token_state_is_read_from_the_token(tmp_path):
  f = tmp_path / "jwt"
  c = ConnectSource(jwt_file=f)
  assert admin.token_status(c)["state"] == "missing"
  f.write_text(_token(time.time() - 60))
  assert admin.token_status(c)["state"] == "expired"
  f.write_text(_token(time.time() + 60))
  assert admin.token_status(c)["state"] == "ok"


def test_a_token_is_kept_only_if_connect_accepts_it_and_only_this_user_can_read_it(tmp_path, monkeypatch):
  f = tmp_path / "dir" / "jwt"
  c = ConnectSource(jwt_file=f)

  def refuse(token):
    raise SourceError("comma Connect answered 401")

  monkeypatch.setattr(c, "check_token", refuse)
  with pytest.raises(SourceError):
    admin.save_token(c, "bad")
  assert not f.exists()
  monkeypatch.setattr(c, "check_token", lambda token: None)
  admin.save_token(c, " good\n")
  assert f.read_text() == "good\n" and stat.S_IMODE(f.stat().st_mode) == 0o600


def test_an_existing_ssh_key_is_never_replaced(tmp_path, monkeypatch):
  monkeypatch.setattr(admin, "SSH_DIR", tmp_path)
  (tmp_path / "id_rsa.pub").write_text("ssh-rsa AAA me\n")
  assert admin.create_key()["public_key"] == "ssh-rsa AAA me"
  assert not (tmp_path / "id_ed25519").exists()


def test_a_new_ssh_key_is_made_when_there_is_none(tmp_path, monkeypatch):
  monkeypatch.setattr(admin, "SSH_DIR", tmp_path / "ssh")
  assert admin.create_key()["public_key"].startswith("ssh-ed25519 ")


def _client(tmp_path):
  return TestClient(server.make_app(cache=tmp_path / "cache", connect=None, output_dir=tmp_path / "movies", settings=Settings(tmp_path / "s.json")))


def test_settings_survive_a_restart_and_a_bare_address_is_completed(tmp_path):
  assert _client(tmp_path).put("/settings", json={"host": "192.168.4.38", "output_dir": "/tmp/clips"}).json()["host"] == "comma@192.168.4.38"
  got = _client(tmp_path).get("/settings").json()
  assert got["host"] == "comma@192.168.4.38" and got["output_dir"] == "/tmp/clips"


def test_the_cache_can_be_cleared_but_not_during_a_job(tmp_path):
  c = _client(tmp_path)
  (tmp_path / "cache" / "route" / "0").mkdir(parents=True)
  (tmp_path / "cache" / "route" / "0" / "rlog.zst").write_bytes(b"x" * 1000)
  assert c.get("/settings").json()["cache_bytes"] == 1000
  assert c.post("/settings/clear-cache").json()["cache_bytes"] == 0


def test_a_seek_finds_the_segment_and_reads_from_a_few_seconds_earlier(tmp_path):
  job = tmp_path / "preview-job.json"
  job.write_text(json.dumps({"frame_count": 2400, "wide_inputs": None}))
  (tmp_path / "preview-index.json").write_text(json.dumps({
    "params": [[0, "p0"], [1200, "p1"]], "offsets": list(range(0, 24000, 10)),
    "segments": [{"first": 0, "skip": 0, "video": "a/fcamera.ts", "wide": "a/e"}, {"first": 1200, "skip": 0, "video": "b/fcamera.ts", "wide": "b/e"}]}))
  got = render.seek(job, 1500)
  assert got["video_inputs"] == ["b/fcamera.ts"] and got["skip_frames"] == 300 and got["frame_count"] == 900
  assert got["clip_offset"] == 14000 and got["frames_before"] == 100 and got["first_lines"] == ["p1"]


def test_a_seek_near_the_start_has_nothing_earlier_to_read(tmp_path):
  job = tmp_path / "preview-job.json"
  job.write_text(json.dumps({"frame_count": 1200, "wide_inputs": None}))
  (tmp_path / "preview-index.json").write_text(json.dumps({"params": [[0, "p0"]], "offsets": list(range(1200)),
                                                           "segments": [{"first": 0, "skip": 40, "video": "a/q.ts", "wide": "a/e"}]}))
  got = render.seek(job, 30)
  assert got["clip_offset"] == 0 and got["frames_before"] == 30 and got["skip_frames"] == 70 and got["video_inputs"] == ["a/q.ts"]


def test_seek_is_refused_for_anything_but_a_prepared_preview(tmp_path):
  assert _client(tmp_path).post("/preview/seek", json={"job_file": "/etc/passwd", "frame": 0}).status_code == 422
