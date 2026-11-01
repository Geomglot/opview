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
