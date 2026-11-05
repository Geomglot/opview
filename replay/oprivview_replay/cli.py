"""Render a drive as an MP4 of the GeoRivView screen.

  python -m oprivview_replay.cli --list
  python -m oprivview_replay.cli 0000005a--f16da7af40 --start-segment 5 --end-segment 6 --view detailed
  python -m oprivview_replay.cli 0000005a--f16da7af40 --from 09:23:33 --to 09:25:10 --dry-run
"""
import argparse
import os
import sys
from pathlib import Path

from . import jobs, params
from .sources import ConnectSource, DeviceSource, SourceError
from .timeline import RangeError

_REPO = Path(__file__).resolve().parents[2]
if sys.platform == "win32":
  DEFAULT_CACHE = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local") / "OPRivViewReplay/Cache"
  DEFAULT_APP = _REPO / "build/windows/x64/runner/Release/OPRivViewReplay.exe"
elif sys.platform.startswith("linux"):
  DEFAULT_CACHE = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "OPRivViewReplay"
  DEFAULT_APP = _REPO / "build/linux/x64/release/bundle/oprivview-replay"
else:
  DEFAULT_CACHE = Path.home() / "Library/Caches/OPRivViewReplay"
  DEFAULT_APP = _REPO / "build/macos/Build/Products/Release/GeoRivView Replay.app/Contents/MacOS/GeoRivView Replay"


def build_parser() -> argparse.ArgumentParser:
  p = argparse.ArgumentParser(prog="oprivview-replay", description="Render a drive as an MP4 of the GeoRivView screen.")
  p.add_argument("route", nargs="?", help="route name, such as 0000005a--f16da7af40")
  p.add_argument("--list", action="store_true", help="list the routes on the comma")
  p.add_argument("--start-segment", type=int, help="first segment to include")
  p.add_argument("--end-segment", type=int, help="last segment to include")
  p.add_argument("--from", dest="start_time", help="start, as local time where the drive happened: HH:MM[:SS]")
  p.add_argument("--to", dest="end_time", help="end, as local time where the drive happened: HH:MM[:SS]")
  p.add_argument("--output", "-o", type=Path, help="MP4 to write; default <route>.mp4")
  p.add_argument("--dry-run", action="store_true", help="show the range without fetching video or rendering")
  p.add_argument("--host", default="comma", help="SSH host of the comma")
  p.add_argument("--no-connect", action="store_true", help="do not use comma Connect")
  p.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="where downloaded drives are kept")
  p.add_argument("--app", type=Path, default=DEFAULT_APP, help="the built renderer")
  params.add_arguments(p)
  return p


def main(argv: list[str] | None = None) -> int:
  args = build_parser().parse_args(argv)
  sources = jobs.Sources(DeviceSource(args.host), None if args.no_connect else ConnectSource())
  if args.list:
    try:
      for route, (source, segments) in sorted(sources.listed().items(), reverse=True):
        print(f"{route}  segments {segments[0]}-{segments[-1]}  ({source.name})")
    except SourceError as e:
      print(e, file=sys.stderr)
      return 1
    return 0
  if not args.route:
    print("give a route name, or --list to see them", file=sys.stderr)
    return 2

  try:
    r = jobs.resolve(sources, args.cache, args.route, args.start_segment, args.end_segment, args.start_time, args.end_time)
  except RangeError as e:
    print(e, file=sys.stderr)
    return 1

  print(f"time zone: {r.timeline.zone.key}")
  print(f"start: {r.timeline.describe(r.start)}")
  print(f"end:   {r.timeline.describe(r.end)}")
  if args.dry_run:
    return 0
  try:
    jobs.render_resolved(r, sources, args.cache, params.job_settings(args), args.output or Path(f"{args.route}.mp4"), args.app)
  except SourceError as e:
    print(e, file=sys.stderr)
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
