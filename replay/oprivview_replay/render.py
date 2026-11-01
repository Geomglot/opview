"""Turn a resolved range into a render: the clip file the renderer reads, and the job describing the output."""
import bisect
import json
import os
import shutil
import subprocess
from pathlib import Path

from .logs import Decoded, load_decoded
from .camera import CameraPicker
from .timeline import FPS, FramePos, RouteTimeline

# messages from before the first frame, so calibration, speed limits and the rest are already right on frame one
PREROLL_FRAMES = 5 * FPS
CAMERA_ASPECT = 1208 / 1928


LOGS = {"full": "rlog.zst", "quick": "qlog.zst"}
VIDEOS = {"full": "fcamera.hevc", "quick": "qcamera.ts"}


def video_frames(path: Path) -> int:
  raw = ["-f", "hevc", "-framerate", str(FPS)] if path.suffix == ".hevc" else []  # a .ts file says what it holds itself
  out = subprocess.run([_tool("ffprobe"), "-v", "error", *raw, "-count_packets",
                        "-select_streams", "v:0", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
                       check=True, capture_output=True, text=True).stdout
  return int(out.split()[0].strip(","))


def _tool(name: str) -> str:
  """the ffmpeg folder the app ships with (OPRIVVIEW_FFMPEG_DIR) first, then whatever is installed on this Mac"""
  bundled = os.environ.get("OPRIVVIEW_FFMPEG_DIR")
  if bundled and (Path(bundled) / name).exists():
    return str(Path(bundled) / name)
  found = shutil.which(name) or shutil.which(name, path="/usr/local/bin:/opt/homebrew/bin")
  if found is None:
    raise FileNotFoundError(f"{name} was not found")
  return found


def _is_idr(src, pos: int) -> bool:
  src.seek(pos)
  head = src.read(8192)
  i = 0
  while (i := head.find(b"\x00\x00\x01", i)) != -1 and i + 3 < len(head):
    nal = (head[i + 3] >> 1) & 0x3F
    if nal < 32:  # the first picture NAL unit: parameter sets and the like come before it
      return nal in (19, 20)
    i += 3
  return False


def keyframe_cut(video: Path, frame: int) -> tuple[Path, int]:
  """A raw camera file can only be decoded from a keyframe, so starting at frame 900 would mean decoding and throwing away
  900 frames first (20 seconds). The file has a keyframe about every 30 frames: copy from the one before [frame], with the
  stream's parameter sets put back in front, and say how many frames of the copy to skip. The pictures come out identical."""
  if video.suffix != ".hevc" or frame == 0:
    return video, frame
  out = subprocess.run([_tool("ffprobe"), "-v", "error", "-f", "hevc", "-framerate", str(FPS), "-select_streams", "v:0",
                        "-show_entries", "packet=pos,flags", "-of", "csv=p=0", str(video)], check=True, capture_output=True, text=True).stdout
  keys = [(n, int(line.split(",")[0])) for n, line in enumerate(out.split()) if "K" in line.split(",")[1]]
  # only a clean IDR picture is safe to start from; an open-GOP keyframe has pictures that lean on earlier ones
  with open(video, "rb") as src:
    safe = [key for key in keys if key[0] <= frame and _is_idr(src, key[1])]
  k, pos = max(safe, default=(0, 0))
  if k == 0:
    return video, frame
  cut = video.with_name(f"{video.stem}-from-{k}.hevc")
  if not cut.exists():
    with open(video, "rb") as src:
      head = src.read(4096)
      # the parameter sets are the NAL units before the first picture (types 32 to 34); copy up to the first one that is not
      i = 0
      while True:
        i = head.index(b"\x00\x00\x01", i)
        if (head[i + 3] >> 1) & 0x3F < 32:
          break
        i += 3
      header = head[:i - 1] if i > 0 and head[i - 1] == 0 else head[:i]
      tmp = cut.with_name(cut.name + ".part")
      with open(tmp, "wb") as dst:
        dst.write(header)
        src.seek(pos)
        while chunk := src.read(1 << 20):
          dst.write(chunk)
    tmp.rename(cut)
  return cut, frame - k


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


def write_clip(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, path: Path, camera: str = "auto",
               wide_checked: bool = True, detail: str = "full") -> tuple[list[str], int, list[str] | None]:
  """write the clip file: messages in order, with an `F <time> <R or W>` line wherever a frame should be drawn
  (R: road camera picture, W: wide camera picture). Returns the road video files, the frame count, and the wide video
  files, or None when no frame uses the wide camera. [wide_checked] False skips reading the wide files, to plan a fetch."""
  segments = [s for s in tl.segments if start.segment <= s <= end.segment]
  log_name, video_name = LOGS[detail], VIDEOS[detail]
  if detail == "quick":
    camera = "road"  # there is no wide camera video in the quick files
  inputs = []
  wide_inputs = []
  count = 0
  picker = CameraPicker(camera)
  used_wide = False
  with open(path, "w") as f:
    def params(decoded: Decoded) -> None:
      f.write(json.dumps({"type": "opviewParams", "valid": True, "data": decoded.params}, separators=(",", ":")) + "\n")

    earlier = preroll_segment(tl, start)
    if earlier is not None:
      previous = load_decoded(route_dir / str(earlier), log_name)
      params(previous)
      last = len(previous.frame_ids)
      for frame, text in by_frame(previous):
        if last - (PREROLL_FRAMES - start.frame) <= frame < last:
          f.write(text + "\n")
          picker.feed(text)

    for seg in segments:
      video = route_dir / str(seg) / video_name
      wide = route_dir / str(seg) / "ecamera.hevc"
      decoded = load_decoded(route_dir / str(seg), log_name)
      params(decoded)
      available = min(len(decoded.frame_times), video_frames(video) if wide_checked else len(decoded.frame_times))
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
            picker.feed(messages[n][1])
          n += 1
        used_wide |= picker.wide
        f.write(f"F {local_ms(tl, seg, decoded.frame_times[frame])} {picker.letter}\n")
        count += 1
      inputs.append(str(video))
      wide_inputs.append(str(wide))
      if wide_checked and picker.wide and wide.exists() and video_frames(wide) != video_frames(video):
        raise RuntimeError(f"segment {seg}: the wide camera has {video_frames(wide)} frames but the road camera has {video_frames(video)}")
  return inputs, count, (wide_inputs if used_wide else None)


def wide_segments(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, camera: str, detail: str = "full") -> list[int]:
  """segments whose wide camera file is needed. Every segment of the range is read in step, so it is all or none."""
  if camera == "road" or detail == "quick":
    return []
  _, _, wide = write_clip(tl, route_dir, start, end, Path(os.devnull), camera, wide_checked=False, detail=detail)
  return [s for s in tl.segments if start.segment <= s <= end.segment] if wide else []


def _cut(video: str, frame: int) -> tuple[str, int]:
  path, skip = keyframe_cut(Path(video), frame)
  return str(path), skip


def prepare(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, settings: dict, output: Path, progress=print,
            detail: str = "full", name: str = "job.json") -> Path:
  """write the clip and the job file the renderer reads, and return the job file"""
  clip = route_dir / name.replace("job", "clip").replace(".json", ".txt")
  inputs, count, wide_inputs = write_clip(tl, route_dir, start, end, clip, settings["camera"], detail=detail)
  video_height = round(settings["video_width"] * CAMERA_ASPECT / 2) * 2
  skip, wide_skip = start.frame, start.frame
  if inputs:
    inputs[0], skip = _cut(inputs[0], start.frame)
  if wide_inputs:
    wide_inputs[0], wide_skip = _cut(wide_inputs[0], start.frame)
  job = {**settings, "clip": str(clip), "output": str(output.resolve()), "ffmpeg": _tool("ffmpeg"), "encoder": "h264_videotoolbox",
         "video_format": "hevc" if detail == "full" else "mpegts", "video_inputs": inputs, "wide_inputs": wide_inputs,
         "skip_frames": skip, "wide_skip_frames": wide_skip, "frame_count": count, "video_height": video_height, "fps": FPS}
  job_path = route_dir / name
  job_path.write_text(json.dumps(job, indent=1))
  progress(f"{count} frames ({count / FPS:.1f} s of drive)")
  return job_path


def run(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, settings: dict, output: Path, app: Path, progress=print,
        detail: str = "full") -> None:
  job_path = prepare(tl, route_dir, start, end, settings, output, progress, detail)
  progress(f"rendering to {output}")
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
