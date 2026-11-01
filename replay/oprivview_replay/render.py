"""Turn a resolved range into a render: the clip file the renderer reads, and the job describing the output."""
import bisect
import json
import os
import shutil
import subprocess
from pathlib import Path

from .logs import Decoded, load_decoded
from .timeline import FPS, FramePos, RouteTimeline

# messages from before the first frame, so calibration, speed limits and the rest are already right on frame one
PREROLL_FRAMES = 5 * FPS
CAMERA_ASPECT = 1208 / 1928


def video_frames(path: Path) -> int:
  out = subprocess.run([_tool("ffprobe"), "-v", "error", "-f", "hevc", "-framerate", str(FPS), "-count_packets",
                        "-select_streams", "v:0", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
                       check=True, capture_output=True, text=True).stdout
  return int(out.strip().strip(",").split(",")[0])


def _tool(name: str) -> str:
  found = shutil.which(name) or shutil.which(name, path="/usr/local/bin:/opt/homebrew/bin")
  if found is None:
    raise FileNotFoundError(f"{name} was not found")
  return found


def by_frame(decoded: Decoded) -> list[tuple[int, str]]:
  """(frame, message) in delivery order. The path and lanes go with the exact frame they were worked out from;
  everything else goes with the first frame finished after it was sent, which is when a viewer could have seen it"""
  ranked = []
  for n, (mono, model_frame, text) in enumerate(decoded.messages):
    if model_frame is not None:
      frame = bisect.bisect_left(decoded.frame_ids, model_frame)
    else:
      frame = bisect.bisect_left(decoded.frame_times, mono)
    ranked.append((frame, n, text))
  ranked.sort()
  return [(frame, text) for frame, _, text in ranked]


def preroll_segment(tl: RouteTimeline, start: FramePos) -> int | None:
  if start.frame >= PREROLL_FRAMES:
    return None
  return start.segment - 1 if start.segment - 1 in tl.segments else None


def local_ms(tl: RouteTimeline, segment: int, mono: int) -> int:
  """the wall clock of the drive's time zone, as a count of milliseconds the app can read directly as hours and minutes"""
  wall_ms = (mono + tl.index[segment].wall_offset_ns) // 1_000_000
  from datetime import datetime
  return wall_ms + int(datetime.fromtimestamp(wall_ms / 1000, tl.zone).utcoffset().total_seconds() * 1000)


def write_clip(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, path: Path) -> tuple[list[str], int]:
  """write the clip file: messages in order, with an `F <time>` line wherever a frame should be drawn"""
  segments = [s for s in tl.segments if start.segment <= s <= end.segment]
  inputs = []
  count = 0
  with open(path, "w") as f:
    def params(decoded: Decoded) -> None:
      f.write(json.dumps({"type": "opviewParams", "valid": True, "data": decoded.params}, separators=(",", ":")) + "\n")

    earlier = preroll_segment(tl, start)
    if earlier is not None:
      previous = load_decoded(route_dir / str(earlier))
      params(previous)
      last = len(previous.frame_ids)
      for frame, text in by_frame(previous):
        if last - (PREROLL_FRAMES - start.frame) <= frame < last:
          f.write(text + "\n")

    for seg in segments:
      camera = route_dir / str(seg) / "fcamera.hevc"
      decoded = load_decoded(route_dir / str(seg))
      params(decoded)
      available = min(len(decoded.frame_times), video_frames(camera))
      if available != len(decoded.frame_times) and seg != segments[-1]:
        print(f"warning: segment {seg} has {available} camera frames for {len(decoded.frame_times)} logged; picture may slip after it")
      first = start.frame if seg == start.segment else 0
      stop = min(end.frame if seg == end.segment else available - 1, available - 1)
      messages = by_frame(decoded)
      n = 0
      for frame in range(first, stop + 1):
        while n < len(messages) and messages[n][0] <= frame:
          if messages[n][0] > first - PREROLL_FRAMES:
            f.write(messages[n][1] + "\n")
          n += 1
        f.write(f"F {local_ms(tl, seg, decoded.frame_times[frame])}\n")
        count += 1
      inputs.append(str(camera))
  return inputs, count


def run(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, settings: dict, output: Path, app: Path, progress=print) -> None:
  clip = route_dir / "clip.txt"
  inputs, count = write_clip(tl, route_dir, start, end, clip)
  video_height = round(settings["video_width"] * CAMERA_ASPECT / 2) * 2
  job = {**settings, "clip": str(clip), "output": str(output.resolve()), "ffmpeg": _tool("ffmpeg"), "encoder": "h264_videotoolbox",
         "video_inputs": inputs, "skip_frames": start.frame, "frame_count": count, "video_height": video_height, "fps": FPS}
  job_path = route_dir / "job.json"
  job_path.write_text(json.dumps(job, indent=1))
  progress(f"rendering {count} frames ({count / FPS:.1f} s of drive) to {output}")
  proc = subprocess.Popen([str(app)], env={**os.environ, "OPRIVVIEW_JOB": str(job_path)}, stderr=subprocess.PIPE, text=True)
  tail = []
  for line in proc.stderr:
    line = line.rstrip()
    if line.startswith("frame "):
      progress(line)
    else:
      tail = (tail + [line])[-20:]
  if proc.wait() != 0:
    raise subprocess.CalledProcessError(proc.returncode, str(app), stderr="\n".join(tail))
