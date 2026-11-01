"""Which camera the app would have been showing: the same rule as ConnectionManager._switchStreamIfNeeded
(lib/services/connection_manager.dart). In experimental mode the wide camera is used below 10 m/s and the road
camera above 15 m/s, keeping whichever it had in between; outside experimental mode it is always the road camera."""
import json

WIDE_BELOW = 10.0
ROAD_ABOVE = 15.0
MODES = ("auto", "road", "wide")


class CameraPicker:
  def __init__(self, mode: str = "auto"):
    if mode not in MODES:
      raise ValueError(f"camera must be one of {', '.join(MODES)}")
    self.mode = mode
    self.experimental = False
    self.speed = 0.0
    self.wide = mode == "wide"

  def feed(self, text: str) -> None:
    """look at one message line as the app would receive it"""
    if text.startswith('{"type":"carState"'):
      self.speed = float(json.loads(text)["data"].get("vEgo") or 0.0)
    elif text.startswith('{"type":"selfdriveState"'):
      self.experimental = bool(json.loads(text)["data"].get("experimentalMode"))
    else:
      return
    if self.mode == "auto":
      if not self.experimental:
        self.wide = False
      elif self.speed < WIDE_BELOW:
        self.wide = True
      elif self.speed > ROAD_ABOVE:
        self.wide = False

  @property
  def letter(self) -> str:
    return "W" if self.wide else "R"
