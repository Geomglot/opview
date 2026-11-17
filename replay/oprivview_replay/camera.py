"""Which camera the app would have been showing: the same rule as cameraTarget (lib/services/connection_manager.dart),
which follows the comma's own screen.

Branches without Experimental mode (geo-dev10-a, geo-dev10plus-a) say whether openpilot controls longitudinal, as
opviewParams OpenpilotLongitudinalControl. When it does, the wide camera is used below 5 m/s and the road camera above
10 m/s. Older branches leave the key out: in experimental mode the wide camera is used below 10 m/s and the road camera
above 15 m/s. Either way the camera in between is kept, and otherwise it is always the road camera."""
import json

# the older Experimental mode rule
WIDE_BELOW = 10.0
ROAD_ABOVE = 15.0
# branches without Experimental mode: whenever openpilot controls longitudinal
LONG_WIDE_BELOW = 5.0
LONG_ROAD_ABOVE = 10.0
MODES = ("auto", "road", "wide")


class CameraPicker:
  def __init__(self, mode: str = "auto"):
    if mode not in MODES:
      raise ValueError(f"camera must be one of {', '.join(MODES)}")
    self.mode = mode
    self.experimental = False
    self.openpilot_long: bool | None = None  # None: the branch has the older Experimental mode rule
    self.speed = 0.0
    self.wide = mode == "wide"

  def feed(self, text: str) -> None:
    """look at one message line as the app would receive it"""
    if text.startswith('{"type":"carState"'):
      self.speed = float(json.loads(text)["data"].get("vEgo") or 0.0)
    elif text.startswith('{"type":"selfdriveState"'):
      self.experimental = bool(json.loads(text)["data"].get("experimentalMode"))
    elif text.startswith('{"type":"opviewParams"'):
      value = json.loads(text)["data"].get("OpenpilotLongitudinalControl")
      self.openpilot_long = None if value is None else bool(value)
    else:
      return
    if self.mode == "auto":
      if self.openpilot_long is None:
        use_wide, below, above = self.experimental, WIDE_BELOW, ROAD_ABOVE
      else:
        use_wide, below, above = self.openpilot_long, LONG_WIDE_BELOW, LONG_ROAD_ABOVE
      if not use_wide:
        self.wide = False
      elif self.speed < below:
        self.wide = True
      elif self.speed > above:
        self.wide = False

  @property
  def letter(self) -> str:
    return "W" if self.wide else "R"
