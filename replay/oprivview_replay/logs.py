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
# the speed setting's param on branches that send longitudinalPlanSP.modelSpeedOff (earlier "Model Controls Speed")
LEGACY_SPEED_PARAMS = ("LegacySpeedControl", "ModelControlsSpeed")
# bump when the decoded format changes, so stale cache files are not reused
DECODED_VERSION = 4


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
  brand, flags, long = "", 0, False
  saved = entries.get("CarParamsPersistent")
  if saved:
    with _car.CarParams.from_bytes(saved) as cp:
      brand, flags, long = str(cp.brand), int(cp.flags), bool(cp.openpilotLongitudinalControl)
  out: dict = {"CarBrand": brand, "CarFlags": flags}
  if "ExperimentalMode" not in entries:
    # a branch without Experimental mode, whose screen picks the camera by this instead (camera.py)
    out["OpenpilotLongitudinalControl"] = long
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
  # The vendored schema has modelSpeedOff, so it would read as false on every drive. Live, it reaches the app only
  # from branches with the Legacy (Chill) setting, which the app uses to choose between it and experimentalMode.
  legacy_setting = False
  for e in events(rlog):
    which = e.which()
    mono = e.logMonoTime
    if which == "initData":
      entries = {p.key: bytes(p.value) for p in e.initData.params.entries}
      out.params = opview_params(entries)
      legacy_setting = any(k in entries for k in LEGACY_SPEED_PARAMS)
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
      if which == "longitudinalPlanSP" and not legacy_setting:
        data.pop("modelSpeedOff", None)
      text = json.dumps({"type": which, "logMonoTime": mono, "valid": e.valid, "data": data}, separators=(",", ":"))
      out.messages.append([mono, msg.frameId if which == "modelV2" else None, text])
  frames.sort()
  out.frame_ids = [f[1] for f in frames]
  out.frame_times = [f[2] for f in frames]
  return out


def load_decoded(segment_dir: Path, log_name: str = "rlog.zst") -> Decoded:
  """decode a segment's log, or read the saved result. qlog results are kept apart from rlog results."""
  stem = "decoded" if log_name == "rlog.zst" else "decoded-" + log_name.split(".")[0]
  cached = segment_dir / f"{stem}-v{DECODED_VERSION}.json"
  if cached.exists():
    return Decoded(**json.loads(cached.read_text()))
  decoded = decode_rlog(segment_dir / log_name)
  cached.write_text(json.dumps(asdict(decoded), separators=(",", ":")))
  return decoded
