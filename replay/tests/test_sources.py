from pathlib import Path

import pytest

from oprivview_replay import jobs, sources
from oprivview_replay.sources import SourceError


class Fake:
  def __init__(self, name, listing, has=()):
    self.name, self.listing, self.has = name, listing, set(has)

  def routes(self):
    if self.listing is None:
      raise SourceError("cannot reach")
    return self.listing

  def available(self):
    return True

  def missing(self, route, segments, names):
    return [n for n in names if n not in self.has]


def resolved(source, segs=(0, 1)):
  return jobs.Resolved("r", list(segs), Path("."), None, None, None, source)


def test_device_wins_when_it_has_the_drive():
  device, connect = Fake("device", {"r": [0, 1]}, ("rlog.zst", "fcamera.hevc", "qlog.zst", "qcamera.ts")), Fake("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  assert jobs.Sources(device, connect).listed()["r"][0] is device


def test_connect_is_used_when_the_comma_is_off():
  device, connect = Fake("device", None), Fake("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts"))
  src, segs = jobs.Sources(device, connect).listed()["r"]
  assert src is connect and segs == [0, 1]
  # full files are not on Connect and the comma cannot be reached, so auto falls back to quick and full is refused
  r = resolved(connect)
  assert jobs.choose_files(r, jobs.Sources(device, connect), [0, 1], "auto") == (connect, "quick")
  with pytest.raises(SourceError, match="Use quick detail"):
    jobs.choose_files(r, jobs.Sources(device, connect), [0, 1], "full")


def test_full_files_found_on_connect_when_uploaded():
  connect = Fake("connect", {"r": [0, 1]}, ("qlog.zst", "qcamera.ts", "rlog.zst", "fcamera.hevc"))
  assert jobs.choose_files(resolved(connect), jobs.Sources(Fake("device", None), connect), [0, 1], "auto") == (connect, "full")


def test_quick_is_honoured_even_when_full_exists():
  device = Fake("device", {"r": [0, 1]}, ("rlog.zst", "fcamera.hevc", "qlog.zst", "qcamera.ts"))
  assert jobs.choose_files(resolved(device), jobs.Sources(device, None), [0, 1], "quick") == (device, "quick")


def test_connect_distance_is_miles_and_is_listed_in_km(monkeypatch, tmp_path):
  from oprivview_replay.sources import ConnectSource
  c = ConnectSource(tmp_path / "no-token")
  monkeypatch.setattr(c, "dongle", lambda: "d")
  row = {"fullname": "d|0000005a--f16da7af40", "segment_numbers": [0], "start_time_utc_millis": 1, "end_time_utc_millis": 2, "distance": 10.0}
  monkeypatch.setattr(c, "_get", lambda path: [row])
  assert c.listing()["0000005a--f16da7af40"]["km"] == 16.09344


def test_tls_context_has_the_ca_certificates_loaded():
  assert sources.TLS.cert_store_stats()["x509_ca"] > 0


def test_no_saved_km_setting_means_miles_as_on_the_comma(monkeypatch):
  from oprivview_replay import ssh_source
  for saved, metric in (("1\n", True), ("0", False), ("", False)):
    monkeypatch.setattr(ssh_source, "run", lambda host, command: saved)
    assert ssh_source.is_metric("comma") is metric
