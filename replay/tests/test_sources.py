from pathlib import Path

import pytest

from oprivview_replay import jobs
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
