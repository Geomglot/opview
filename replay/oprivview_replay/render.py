"""Turn a resolved range into a render: the clip file the renderer reads, and the job describing the output."""
import bisect
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable

from .logs import Decoded, load_decoded
from .camera import CameraPicker
from .timeline import FPS, FramePos, RouteTimeline

# messages from before the first frame, so calibration, speed limits and the rest are already right on frame one
PREROLL_FRAMES = 5 * FPS
CAMERA_ASPECT = 1208 / 1928


# "logs" is what comma Connect often has: the complete log, which has the path and lane lines, with the small video
LOGS = {"full": "rlog.zst", "logs": "rlog.zst", "quick": "qlog.zst"}
VIDEOS = {"full": "fcamera.hevc", "logs": "qcamera.ts", "quick": "qcamera.ts"}
SEEK_PREROLL_FRAMES = PREROLL_FRAMES


def video_frames(path: Path) -> int:
  raw = ["-f", "hevc", "-framerate", str(FPS)] if path.suffix == ".hevc" else []  # a .ts file says what it holds itself
  out = subprocess.run([_tool("ffprobe"), "-v", "error", *raw, "-count_packets",
                        "-select_streams", "v:0", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
                       check=True, capture_output=True, text=True).stdout
  return int(out.split()[0].strip(","))


def _tool(name: str) -> str:
  """the ffmpeg folder the app ships with (OPRIVVIEW_FFMPEG_DIR) first, then whatever is installed on this computer"""
  bundled = os.environ.get("OPRIVVIEW_FFMPEG_DIR")
  file = name + ".exe" if sys.platform == "win32" else name
  if bundled and (Path(bundled) / file).exists():
    return str(Path(bundled) / file)
  found = shutil.which(name)
  if found is None and sys.platform != "win32":
    found = shutil.which(name, path="/usr/local/bin:/opt/homebrew/bin")
  if found is None:
    raise FileNotFoundError(f"{name} was not found")
  return found


# Windows: the graphics card's own encoder if there is one (NVIDIA, Intel, AMD), else Windows' built-in one (Media
# Foundation). The ffmpeg shipped is LGPL, so it has no x264 to fall back on.
WINDOWS_ENCODERS = ("h264_nvenc", "h264_qsv", "h264_amf", "h264_mf")
NO_ENCODER = ("This computer has no H.264 video encoder that ffmpeg can use: no NVIDIA, Intel or AMD graphics encoder "
              "answered, and Windows' own Media Foundation encoder is missing too. On a Windows \"N\" edition, install "
              "the Media Feature Pack from Settings > Apps > Optional features, then try again.")
_encoders: dict[str, str] = {}


def encoder(ffmpeg: str) -> str:
  """the H.264 encoder the renderer is told to use. On a Mac always VideoToolbox. On Windows, the first that can
  really encode a frame here: an encoder can be built into ffmpeg yet have no hardware behind it. Checked once."""
  if sys.platform != "win32":
    return "h264_videotoolbox"
  if ffmpeg not in _encoders:
    # two blank frames in through a pipe and out through one, using only what the app's own small ffmpeg holds
    frames = bytes(256 * 144 * 3 // 2 * 2)  # 256x144 yuv420p
    for name in WINDOWS_ENCODERS:
      try:
        subprocess.run([ffmpeg, "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "256x144", "-r", "20", "-i", "-",
                        "-c:v", name, "-f", "rawvideo", "-"], input=frames, check=True, capture_output=True, timeout=30)
      except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        continue
      _encoders[ffmpeg] = name
      break
    else:
      raise RuntimeError(NO_ENCODER)
  return _encoders[ffmpeg]


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
               wide_checked: bool = True, detail: str = "full", index: dict | None = None) -> tuple[list[str], int, list[str] | None]:
  """write the clip file: messages in order, with an `F <time> <R or W>` line wherever a frame should be drawn
  (R: road camera picture, W: wide camera picture). Returns the road video files, the frame count, and the wide video
  files, or None when no frame uses the wide camera. [wide_checked] False skips reading the wide files, to plan a fetch.
  [index] is filled with what a jump to any frame needs: see [seek]."""
  segments = [s for s in tl.segments if start.segment <= s <= end.segment]
  log_name, video_name = LOGS[detail], VIDEOS[detail]
  if VIDEOS[detail] != "fcamera.hevc":
    camera = "road"  # the wide camera has no small version
  inputs = []
  wide_inputs = []
  count = 0
  picker = CameraPicker(camera)
  used_wide = False
  with open(path, "w") as f:
    def params(decoded: Decoded) -> None:
      line = json.dumps({"type": "opviewParams", "valid": True, "data": decoded.params}, separators=(",", ":"))
      f.write(line + "\n")
      if index is not None:
        index["params"].append([count, line])

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
      if index is not None:
        index["segments"].append({"segment": seg, "first": count, "skip": first, "video": str(video), "wide": str(wide)})
      for frame in range(first, stop + 1):
        if index is not None:
          index["offsets"].append(f.tell())  # where the messages for this frame start
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
  if camera == "road" or VIDEOS[detail] != "fcamera.hevc":
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
  index: dict = {"params": [], "segments": [], "offsets": []}
  inputs, count, wide_inputs = write_clip(tl, route_dir, start, end, clip, settings["camera"], detail=detail, index=index)
  video_height = round(settings["video_width"] * CAMERA_ASPECT / 2) * 2
  skip, wide_skip = start.frame, start.frame
  if inputs:
    inputs[0], skip = _cut(inputs[0], start.frame)
  if wide_inputs:
    wide_inputs[0], wide_skip = _cut(wide_inputs[0], start.frame)
  ffmpeg = _tool("ffmpeg")
  job = {**settings, "clip": str(clip), "output": str(output.resolve()), "ffmpeg": ffmpeg, "encoder": encoder(ffmpeg),
         "video_format": "hevc" if VIDEOS[detail].endswith(".hevc") else "mpegts", "video_inputs": inputs, "wide_inputs": wide_inputs,
         "skip_frames": skip, "wide_skip_frames": wide_skip, "frame_count": count, "video_height": video_height, "fps": FPS,
         # where each segment starts in the clip and how far into it the clip starts, so the preview can say where it is
         "segment_starts": [[s["segment"], s["first"], s["skip"]] for s in index["segments"]]}
  job_path = route_dir / name
  job_path.write_text(json.dumps(job, indent=1))
  _index_file(job_path).write_text(json.dumps(index, separators=(",", ":")))
  progress(f"{count} frames ({count / FPS:.1f} s of drive)")
  return job_path


def _index_file(job_path: Path) -> Path:
  return job_path.with_name(job_path.name.replace("job", "index"))


def seek(job_path: Path, frame: int) -> dict:
  """what changes in a job to play it from [frame] of its clip. The clip is read from a few seconds earlier without drawing,
  as a render does before its first frame, so calibration and the rest are right on the picture the jump lands on."""
  job = json.loads(job_path.read_text())
  index = json.loads(_index_file(job_path).read_text())
  frame = max(0, min(frame, job["frame_count"] - 1))
  starts = [s["first"] for s in index["segments"]]
  at = bisect.bisect_right(starts, frame) - 1
  here, later = index["segments"][at], index["segments"][at + 1:]
  local = here["skip"] + frame - here["first"]
  video, skip = _cut(here["video"], local)
  wide = {"wide_inputs": None, "wide_skip_frames": 0}
  if job.get("wide_inputs"):
    first_wide, wide_skip = _cut(here["wide"], local)
    wide = {"wide_inputs": [first_wide] + [s["wide"] for s in later], "wide_skip_frames": wide_skip}
  read_from = max(0, frame - SEEK_PREROLL_FRAMES)
  params = [line for first, line in index["params"] if first <= frame][-1:]
  return {"video_inputs": [video] + [s["video"] for s in later], "skip_frames": skip, **wide, "frame_count": job["frame_count"] - frame,
          "clip_offset": index["offsets"][read_from], "frames_before": frame - read_from, "first_lines": params}


def snapshot_file(route_dir: Path) -> Path:
  """a small picture of the frame a render has reached, which the renderer replaces about once a second while it works"""
  return route_dir / "render-snapshot.bmp"


def partial_file(output: Path) -> Path:
  """where a render stopped early with Save is kept: marked as part of the range, and never over an earlier clip"""
  path = output.with_name(f"{output.stem} (partial){output.suffix}")
  n = 2
  while path.exists():
    path = output.with_name(f"{output.stem} (partial {n}){output.suffix}")
    n += 1
  return path


def request_stop(proc: subprocess.Popen) -> None:
  """ask a running renderer to finish the clip at the frame it has reached: it closes the video properly and says
  "stopped at frame N". Killing it instead leaves a file that will not play."""
  try:
    proc.stdin.write("stop\n")
    proc.stdin.flush()
  except (OSError, ValueError):
    pass  # it has just ended by itself; what it wrote is handled as usual


def part_file(output: Path) -> Path:
  """where a clip is written until it is complete; ffmpeg goes by the last part of the name, so that stays .mp4"""
  return output.with_name(output.stem + ".part" + output.suffix)


def run(tl: RouteTimeline, route_dir: Path, start: FramePos, end: FramePos, settings: dict, output: Path, app: Path, progress=print,
        detail: str = "full", started: Callable[[subprocess.Popen], None] | None = None) -> Path | None:
  """the clip only appears at [output] once every frame is in it. [started] is given the renderer, so it can be stopped:
  killed, which saves nothing, or asked with [request_stop] to finish early, which saves the frames so far at
  [partial_file]. Returns where the clip was saved, or None if it was stopped before its first frame."""
  part = part_file(output)
  job_path = prepare(tl, route_dir, start, end, settings, part, progress, detail)
  wanted = json.loads(job_path.read_text())["frame_count"]
  snapshot = snapshot_file(route_dir)
  _remove(snapshot)  # one left by an earlier render would show the wrong picture
  progress(f"rendering to {output}")
  # the pipe to its stdin closes when this process ends, however it ends, and the renderer stops on that
  proc = subprocess.Popen([str(app)], env={**os.environ, "OPRIVVIEW_JOB": str(job_path), "OPRIVVIEW_WATCH_STDIN": "1",
                                           "OPRIVVIEW_SNAPSHOT": str(snapshot)},
                          stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
  if started:
    started(proc)
  tail = []
  stopped_at = None
  try:
    for line in proc.stderr:
      line = line.rstrip()
      if line.startswith("frame "):
        progress(line)
      elif line.startswith("stopped at frame "):
        stopped_at = int(line.split()[-1])
      else:
        tail = (tail + [line])[-20:]
    if proc.wait() != 0:
      raise subprocess.CalledProcessError(proc.returncode, str(app), stderr="\n".join(tail))
    if stopped_at == 0:
      return None
    if stopped_at is not None:
      wanted, output = stopped_at, partial_file(output)
    written = video_frames(part)
    if written != wanted:
      raise RuntimeError(f"the render stopped early: {written} of {wanted} frames were written")
    part.replace(output)
    return output
  finally:
    for leftover in (part, snapshot, snapshot.with_name(snapshot.name + ".part")):
      _remove(leftover, patience=3.0)


def _remove(path: Path, patience: float = 0.0) -> None:
  """Windows will not delete a file another program has open: ffmpeg holds the part file for a moment after a stopped
  renderer, and the window may be reading the picture. Try again for up to [patience] seconds, then leave it; a later
  render replaces both."""
  import time

  deadline = time.monotonic() + patience
  while True:
    try:
      path.unlink(missing_ok=True)
      return
    except OSError:
      if time.monotonic() >= deadline:
        return
      time.sleep(0.1)
