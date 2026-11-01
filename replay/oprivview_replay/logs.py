"""Read openpilot logs: a quick index of a route, and the messages the app would have received."""
import json
from collections.abc import Iterator
from dataclasses import asdict, dataclass, field
from pathlib import Path

import capnp
import zstandard

from .vendor import opview_slim
from .vendor.opview_model import opview_model

_VENDOR = Path(__file__).parent / "vendor"
capnp.remove_import_hook()
_log = capnp.load(str(_VENDOR / "log.capnp"), imports=[str(_VENDOR)])
_car = capnp.load(str(_VENDOR / "car.capnp"), imports=[str(_VENDOR)])

# what the app asks webrtcd for (bridgeServicesOut in lib/system/webrtc/webrtcd_api.dart), with the older names
SERVICES = (
  "carState", "selfdriveState", "controlsState", "modelV2", "extrinsicsCalibration", "liveCalibration", "radarState",
  "longitudinalPlan", "deviceState", "narrowRoadCameraState", "roadCameraState", "longitudinalPlanSP", "liveMapDataSP",
  "carControl", "carOutput", "selfdriveStateSP", "onroadEvents", "driverMonitoringState", "carControlSP",
)
_ENCODE_IDX = ("narrowRoadEncodeIdx", "roadEncodeIdx")
BOOL_PARAMS = ("IsMetric", "RoadNameToggle", "RivianForceTorqueSteer", "TrueVEgoUI", "SPLiveSpeedCorrectionEnabled",
               "ShowTurnSignals", "BlindSpot", "LaneCenteringEnabled")
INT_PARAMS = ("SpeedLimitMode", "SPCruiseSpeedOffset")
# bump when the decoded format changes, so stale cache files are not reused
DECODED_VERSION = 1


def events(path: Path) -> Iterator:
  """every message in a log; the last segment of a drive can stop part way through a message, so stop quietly there"""
  with open(path, "rb") as f:
    raw = zstandard.ZstdDecompressor().stream_reader(f).read()
  reader = _log.Event.read_multiple_bytes(raw)
  while True:
    try:
      yield next(reader)
    except StopIteration:
      return
    except capnp.KjException:
      return


def opview_params(entries: dict[str, bytes]) -> dict:
  """the settings webrtcd sends live as opviewParams, rebuilt from the copy saved at the start of each segment"""
  brand, flags = "", 0
  saved = entries.get("CarParamsPersistent")
  if saved:
    with _car.CarParams.from_bytes(saved) as cp:
      brand, flags = str(cp.brand), int(cp.flags)
  out: dict = {"CarBrand": brand, "CarFlags": flags}
  for key in BOOL_PARAMS:
    out[key] = entries.get(key, b"0") == b"1"
  for key in INT_PARAMS:
    try:
      out[key] = int(entries.get(key, b"0"))
    except ValueError:
      out[key] = 0
  return out


@dataclass
class SegmentIndex:
  """enough about one segment to turn a time of day into a frame: from a qlog, which is small"""
  frames: int = 0
  first_mono: int = 0  # end of exposure of the first frame
  wall_offset_ns: int | None = None  # wall time minus log time
  lat: float | None = None
  lon: float | None = None


def index_segment(qlog: Path) -> SegmentIndex:
  idx = SegmentIndex()
  for e in events(qlog):
    which = e.which()
    if which in _ENCODE_IDX:
      enc = getattr(e, which)
      idx.frames += 1
      if idx.frames == 1:
        idx.first_mono = enc.timestampEof
    elif which == "clocks" and idx.wall_offset_ns is None:
      if e.clocks.wallTimeNanos > 1_500_000_000 * 10**9:  # ignore a clock that has not been set yet
        idx.wall_offset_ns = e.clocks.wallTimeNanos - e.logMonoTime
    elif which in ("gpsLocation", "gpsLocationExternal") and idx.lat is None:
      g = getattr(e, which)
      if abs(g.latitude) > 0.01 or abs(g.longitude) > 0.01:
        idx.lat, idx.lon = g.latitude, g.longitude
  return idx


@dataclass
class Decoded:
  frame_ids: list[int] = field(default_factory=list)
  frame_times: list[int] = field(default_factory=list)  # log time of each frame in the video file, in file order
  params: dict = field(default_factory=dict)
  messages: list = field(default_factory=list)  # [log time, model frame id or None, json text], in log order


def decode_rlog(rlog: Path) -> Decoded:
  """the messages the app would have received live: same services, same rates, same fields, same JSON"""
  out = Decoded()
  frames: list[tuple[int, int, int]] = []
  last_sent: dict[str, int] = {}
  for e in events(rlog):
    which = e.which()
    mono = e.logMonoTime
    if which == "initData":
      out.params = opview_params({p.key: bytes(p.value) for p in e.initData.params.entries})
    elif which in _ENCODE_IDX:
      enc = getattr(e, which)
      frames.append((enc.segmentId, enc.frameId, enc.timestampEof))
    elif which in SERVICES:
      gap = opview_slim.min_gap_s(which)
      if gap and mono - last_sent.get(which, 0) < gap * 1e9:
        continue
      last_sent[which] = mono
      msg = getattr(e, which)
      data = opview_model(msg) if which == "modelV2" else opview_slim.slim(which, msg)
      text = json.dumps({"type": which, "logMonoTime": mono, "valid": e.valid, "data": data}, separators=(",", ":"))
      out.messages.append([mono, msg.frameId if which == "modelV2" else None, text])
  frames.sort()
  out.frame_ids = [f[1] for f in frames]
  out.frame_times = [f[2] for f in frames]
  return out


def load_decoded(segment_dir: Path) -> Decoded:
  cached = segment_dir / f"decoded-v{DECODED_VERSION}.json"
  if cached.exists():
    return Decoded(**json.loads(cached.read_text()))
  decoded = decode_rlog(segment_dir / "rlog.zst")
  cached.write_text(json.dumps(asdict(decoded), separators=(",", ":")))
  return decoded
