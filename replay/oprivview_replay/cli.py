"""Render a drive as an MP4 of the OPRivView screen.

  python -m oprivview_replay.cli --list
  python -m oprivview_replay.cli 0000005a--f16da7af40 --start-segment 5 --end-segment 6 --view detailed
  python -m oprivview_replay.cli 0000005a--f16da7af40 --from 09:23:33 --to 09:25:10 --dry-run
"""
import argparse
import sys
from pathlib import Path

from . import params, ssh_source
from .logs import index_segment
from .timeline import RangeError, RouteTimeline, resolve_range, zone_for

DEFAULT_CACHE = Path.home() / "Library/Caches/OPRivViewReplay"
DEFAULT_APP = Path(__file__).resolve().parents[2] / "build/macos/Build/Products/Release/OPRivView Replay.app/Contents/MacOS/OPRivView Replay"


def build_parser() -> argparse.ArgumentParser:
  p = argparse.ArgumentParser(prog="oprivview-replay", description="Render a drive as an MP4 of the OPRivView screen.")
  p.add_argument("route", nargs="?", help="route name, such as 0000005a--f16da7af40")
  p.add_argument("--list", action="store_true", help="list the routes on the comma")
  p.add_argument("--start-segment", type=int, help="first segment to include")
  p.add_argument("--end-segment", type=int, help="last segment to include")
  p.add_argument("--from", dest="start_time", help="start, as local time where the drive happened: HH:MM[:SS]")
  p.add_argument("--to", dest="end_time", help="end, as local time where the drive happened: HH:MM[:SS]")
  p.add_argument("--output", "-o", type=Path, help="MP4 to write; default <route>.mp4")
  p.add_argument("--dry-run", action="store_true", help="show the range without fetching video or rendering")
  p.add_argument("--host", default="comma", help="SSH host of the comma")
  p.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="where downloaded drives are kept")
  p.add_argument("--app", type=Path, default=DEFAULT_APP, help="the built renderer")
  params.add_arguments(p)
  return p


def main(argv: list[str] | None = None) -> int:
  args = build_parser().parse_args(argv)
  if args.list:
    for route, segments in ssh_source.list_routes(args.host).items():
      print(f"{route}  segments {segments[0]}-{segments[-1]}")
    return 0
  if not args.route:
    print("give a route name, or --list to see them", file=sys.stderr)
    return 2

  segments = ssh_source.list_routes(args.host).get(args.route)
  if not segments:
    print(f"{args.route} is not on the comma", file=sys.stderr)
    return 1
  ssh_source.fetch(args.host, args.route, segments, ("qlog.zst",), args.cache)
  route_dir = args.cache / args.route
  index = {s: index_segment(route_dir / str(s) / "qlog.zst") for s in segments}
  located = next((i for i in index.values() if i.lat is not None), None)
  if located is None:
    print("this drive has no GPS position, so its time zone is unknown", file=sys.stderr)
    return 1

  try:
    timeline = RouteTimeline(index, zone_for(located.lat, located.lon))
    start, end = resolve_range(timeline, args.start_segment, args.end_segment, args.start_time, args.end_time)
  except RangeError as e:
    print(e, file=sys.stderr)
    return 1

  print(f"time zone: {timeline.zone.key}")
  print(f"start: {timeline.describe(start)}")
  print(f"end:   {timeline.describe(end)}")
  if args.dry_run:
    return 0

  from . import render
  needed = [s for s in segments if start.segment <= s <= end.segment]
  earlier = render.preroll_segment(timeline, start)
  ssh_source.fetch(args.host, args.route, needed, ("rlog.zst", "fcamera.hevc"), args.cache)
  if earlier is not None:
    ssh_source.fetch(args.host, args.route, [earlier], ("rlog.zst",), args.cache)
  render.run(timeline, route_dir, start, end, params.job_settings(args), args.output or Path(f"{args.route}.mp4"), args.app)
  return 0


if __name__ == "__main__":
  sys.exit(main())
