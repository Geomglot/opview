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

  @property
  def flag(self) -> str:
    return "--" + self.name.replace("_", "-")


PARAMS = (
  Param("view", "which OPRivView layout to draw", "classic", ("classic", "enhanced", "detailed")),
  Param("bottom_bar", "bottom bar; default is the app's own choice for the view", None,
        ("torque", "laneCentering", "auto", "off")),
  Param("detail", "full: the complete log and camera video. quick: the small files comma Connect keeps; no path or lane lines "
        "and a low resolution picture. auto: full when it can be had", "auto", ("auto", "full", "quick")),
  Param("camera", "picture behind the overlays: auto follows the app (wide camera at low speed in experimental mode)", "auto",
        ("auto", "road", "wide")),
  Param("collapsed_panels", "Detailed panels to fold shut", (), ("steering", "driver", "longitudinal", "lead"), many=True),
  Param("clock", "clock format", "h12", ("h12", "h24")),
  Param("width", "output width in pixels", 1920, type=int),
  Param("height", "output height in pixels", 1080, type=int),
  Param("video_width", "camera picture width fed to the layouts; the live stream is 1152", 1152, type=int),
  Param("bitrate", "output video bitrate", "8M"),
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
           "choices": list(p.choices) if p.choices else None, "kind": kinds[p.type], "many": p.many} for p in PARAMS]


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
