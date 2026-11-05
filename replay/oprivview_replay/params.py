"""Every option a replay job takes, in one list.

The command line is built from this list, and the desktop interface will be too. To add an option, add one Param
here and read it in lib/replay/replay_job.dart if the renderer needs it.
"""
import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class Param:
  name: str
  help: str
  default: object = None
  choices: tuple | None = None
  type: type = str
  many: bool = False
  advanced: bool = False  # kept out of the way in the window, under Advanced

  @property
  def flag(self) -> str:
    return "--" + self.name.replace("_", "-")


PARAMS = (
  Param("view", "Which GeoRivView screen layout to draw", "classic", ("classic", "enhanced", "detailed")),
  Param("bottom_bar", "App default is what the app normally shows for this view", None,
        ("torque", "laneCentering", "auto", "off")),
  Param("detail", "Full uses the complete log and camera video. Log with small video has the path and lane lines over a lower "
        "resolution picture. Quick uses only the small files, with no path or lane lines. Automatic uses the best the drive has",
        "auto", ("auto", "full", "logs", "quick")),
  Param("camera", "Automatic follows the app, which uses the wide camera at low speed in experimental mode", "auto",
        ("auto", "road", "wide")),
  Param("collapsed_panels", "Detailed view only: the panels to fold shut", (), ("steering", "driver", "longitudinal", "lead"), many=True),
  Param("clock", "", "h12", ("h12", "h24")),
  Param("speed_limit", "Automatic shows it once the comma has a speed limit", "auto", ("auto", "always", "off")),
  Param("road_name", "", "show", ("show", "hide")),
  Param("width", "Width of the MP4 in pixels", 1920, type=int, advanced=True),
  Param("height", "Height of the MP4 in pixels", 1080, type=int, advanced=True),
  Param("video_width", "Width of the camera picture behind the overlays. The live stream is 1152", 1152, type=int, advanced=True),
  Param("bitrate", "MP4 video bitrate, for example 8M", "8M", advanced=True),
)


def add_arguments(parser: argparse.ArgumentParser) -> None:
  for p in PARAMS:
    kwargs: dict = {"help": p.help, "default": list(p.default) if p.many else p.default, "choices": p.choices}
    if p.many:
      kwargs["nargs"] = "*"
    else:
      kwargs["type"] = p.type
    parser.add_argument(p.flag, **kwargs)


def job_settings(args: argparse.Namespace) -> dict:
  return {p.name: getattr(args, p.name) for p in PARAMS}


def describe() -> list[dict]:
  """the list as plain data, for the interface to build its form from"""
  kinds = {str: "text", int: "integer"}
  return [{"name": p.name, "label": p.name.replace("_", " "), "help": p.help, "default": list(p.default) if p.many else p.default,
           "choices": list(p.choices) if p.choices else None, "kind": kinds[p.type], "many": p.many, "advanced": p.advanced}
          for p in PARAMS]


def settings_from_dict(values: dict) -> dict:
  """job settings from a dict of user choices; anything left out takes its default, anything invalid raises ValueError"""
  unknown = set(values) - {p.name for p in PARAMS}
  if unknown:
    raise ValueError(f"unknown option: {', '.join(sorted(unknown))}")
  out = {}
  for p in PARAMS:
    v = values.get(p.name, list(p.default) if p.many else p.default)
    if p.many:
      v = list(v or [])
      bad = [x for x in v if p.choices and x not in p.choices]
      if bad:
        raise ValueError(f"{p.name}: {bad[0]!r} is not one of {', '.join(p.choices)}")
    elif v is not None:
      v = p.type(v)
      if p.choices and v not in p.choices:
        raise ValueError(f"{p.name}: {v!r} is not one of {', '.join(p.choices)}")
    out[p.name] = v
  return out
