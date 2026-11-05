"""Renders a short made-up clip with the built app, as the server would, and checks the MP4 has every frame.

It needs no drive and no comma: the camera picture is ffmpeg's test pattern and the clip has no log lines, so the
overlays draw as they do before any data arrives. What it proves is that the app draws and hands its frames to ffmpeg
without a window, which is how the server runs it.

  python tools/render_check.py --app <the built app> [--ffmpeg <ffmpeg>] [--encoder <name> | --bundled <folder>] [--frames 40]

The ffmpeg given makes the test video, so it must have an HEVC encoder (a full ffmpeg, not the app's small one). It also
renders, with --encoder, unless --bundled names the folder of the app's own ffmpeg: then the encoder is chosen as the
server chooses it, which can fall back to the computer's own ffmpeg.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from oprivview_replay.params import PARAMS  # noqa: E402
from oprivview_replay import render  # noqa: E402
from oprivview_replay.render import CAMERA_ASPECT  # noqa: E402
from oprivview_replay.timeline import FPS  # noqa: E402


def main() -> int:
  ap = argparse.ArgumentParser()
  ap.add_argument("--app", required=True)
  ap.add_argument("--ffmpeg", default="ffmpeg")
  ap.add_argument("--encoder", default="libx264")
  ap.add_argument("--bundled")
  ap.add_argument("--frames", type=int, default=40)
  ap.add_argument("--timeout", type=int, default=300)
  args = ap.parse_args()

  work = Path(tempfile.mkdtemp(prefix="render-check-"))
  video = work / "fcamera.hevc"
  subprocess.run([args.ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size=1928x1208:rate={FPS}",
                  "-frames:v", str(args.frames), "-c:v", "libx265", "-x265-params", "log-level=error", "-f", "hevc", str(video)],
                 check=True)
  clip = work / "clip.txt"
  clip.write_text("".join(f"F {n * 1000 // FPS} R\n" for n in range(args.frames)))

  settings = {p.name: list(p.default) if p.many else p.default for p in PARAMS}
  output = work / "check.mp4"
  how = render.Encoding(args.ffmpeg, args.encoder)
  if args.bundled:
    os.environ["OPRIVVIEW_FFMPEG_DIR"] = args.bundled
    how = render.encoding(render._tool("ffmpeg"))
  print(f"encoding with {how}", flush=True)
  device = {"encoder_device": how.device} if how.device else {}
  job = {**settings, "clip": str(clip), "output": str(output), "ffmpeg": how.ffmpeg, "encoder": how.encoder, **device,
         "video_format": "hevc", "video_inputs": [str(video)], "wide_inputs": None, "skip_frames": 0, "wide_skip_frames": 0,
         "frame_count": args.frames, "video_height": round(settings["video_width"] * CAMERA_ASPECT / 2) * 2, "fps": FPS,
         "segment_starts": [[0, 0, 0]]}
  job_path = work / "job.json"
  job_path.write_text(json.dumps(job, indent=1))

  print(f"rendering {args.frames} frames in {work}", flush=True)
  r = subprocess.run([args.app], env={**os.environ, "OPRIVVIEW_JOB": str(job_path)}, timeout=args.timeout)
  if r.returncode != 0:
    print(f"the app exited with {r.returncode}")
    return 1
  ffmpeg = Path(args.ffmpeg)
  ffprobe = str(ffmpeg.with_name(ffmpeg.name.replace("ffmpeg", "ffprobe"))) if ffmpeg.parent != Path() else "ffprobe"
  frames = subprocess.run([ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0",
                           "-show_entries", "stream=nb_read_frames,width,height", "-of", "json", str(output)],
                          check=True, capture_output=True, text=True).stdout
  stream = json.loads(frames)["streams"][0]
  print(f"made {output.name}: {stream}")
  if int(stream["nb_read_frames"]) != args.frames or (stream["width"], stream["height"]) != (settings["width"], settings["height"]):
    print(f"expected {args.frames} frames of {settings['width']}x{settings['height']}")
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
