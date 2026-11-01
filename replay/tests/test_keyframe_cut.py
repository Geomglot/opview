import shutil
import subprocess

import pytest

from oprivview_replay import render

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")


def make_video(path, frames=60, keyint=10, open_gop=False):
  subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc=size=128x96:rate=20:duration={frames / 20}",
                  "-c:v", "libx265", "-x265-params", f"keyint={keyint}:{'open-gop=1' if open_gop else 'open-gop=0'}:log-level=error", "-f", "hevc", str(path)], check=True)


def pixels(path, skip, count=3):
  return subprocess.run(["ffmpeg", "-v", "error", "-f", "hevc", "-framerate", "20", "-i", str(path), "-vf",
                         f"trim=start_frame={skip},setpts=PTS-STARTPTS", "-frames:v", str(count), "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
                        check=True, capture_output=True).stdout


def test_cut_gives_the_same_pictures_as_decoding_from_the_start(tmp_path):
  video = tmp_path / "fcamera.hevc"
  make_video(video)
  cut, skip = render.keyframe_cut(video, 37)
  assert cut != video and 0 <= skip < 37
  assert pixels(cut, skip) == pixels(video, 37)
  assert cut.stat().st_size < video.stat().st_size


def test_start_of_file_and_small_frames_use_the_original(tmp_path):
  video = tmp_path / "fcamera.hevc"
  make_video(video)
  assert render.keyframe_cut(video, 0) == (video, 0)
  assert render.keyframe_cut(video, 4) == (video, 4)  # before the second keyframe


def test_ts_files_are_left_alone(tmp_path):
  ts = tmp_path / "qcamera.ts"
  ts.write_bytes(b"")
  assert render.keyframe_cut(ts, 500) == (ts, 500)


def test_open_gop_keyframes_are_not_used_but_pictures_still_match(tmp_path):
  video = tmp_path / "fcamera.hevc"
  make_video(video, open_gop=True)
  cut, skip = render.keyframe_cut(video, 37)
  assert pixels(cut, skip) == pixels(video, 37)  # whether it cut at an IDR or fell back to the whole file
