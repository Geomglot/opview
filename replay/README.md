# OPRivView replay

Renders a drive as an MP4 of the OPRivView screen. The real onroad layouts draw the drive, fed the same messages
the comma sent the app live, so the result looks as it did in the car.

To use the Mac app, see the [install guide](docs/INSTALL.md) and the [user guide](docs/USER_GUIDE.md). The rest of this page
is for working on the code.

## Setup

Needs Flutter, Xcode, ffmpeg and the `comma` host alias in `~/.ssh/config`.

```bash
python3.12 -m venv replay/.venv
replay/.venv/bin/pip install -r replay/requirements.txt
flutter build macos -t lib/main_replay.dart
```

## Use

Run from `replay/`:

```bash
.venv/bin/python -m oprivview_replay.cli --list
.venv/bin/python -m oprivview_replay.cli 0000005a--f16da7af40 --start-segment 5 --end-segment 6
.venv/bin/python -m oprivview_replay.cli 0000005a--f16da7af40 --from 09:23:20 --to 09:23:40 --view detailed
```

- A start or end can be a segment number or a local time where the drive happened. Each end can use either form.
  With neither, the replay runs from the first or to the last frame of the drive.
- `--dry-run` shows the range without fetching video or rendering.
- If a time happened twice because the clocks went back, add the offset, such as `01:30-04:00`.

## The window

Open `build/macos/Build/Products/Release/OPRivView Replay.app` with no job set and it shows the replay window:
a list of the drives on the comma, a start and end (each a local time or a segment number), a form for every
option (built from the list in `params.py`, so a new option appears with no interface work), and a Render button
with progress. In a development build it starts `python -m oprivview_replay.server` from this folder; set
`OPRIVVIEW_SERVER_URL` to use a server you started yourself, or `OPRIVVIEW_REPLAY_DIR` if the folder is not found.
Preview prepares the range and plays it in the window at the drive's own speed, through the same layouts the export uses
(see In the preview, below). Play after a render opens the finished MP4.

To check the preview in the real engine, prepare a job (POST /jobs with `"preview": true`) and run
`flutter drive --profile -d macos --driver=test_driver/integration_test.dart --target=integration_test/preview_test.dart
--dart-define=PREVIEW_JOB=<preview-job.json> --dart-define=PREVIEW_PNG=<png to write>`.

Starting in the middle of a segment no longer costs a 20 second wait: the camera file is copied from the keyframe before
the start (`keyframe_cut` in render.py), which gives identical pictures. These copies (`fcamera-from-N.hevc`) stay in the
cache until the cache cap exists.

## Building the app

`make app` (in this folder) builds `dist/OPRivView Replay.app` with everything inside: the window, the server
(PyInstaller) and ffmpeg. It runs from any folder on a Mac with no Python or ffmpeg installed. `make install` copies it
to /Applications; `make clean` removes the build and the installed copy. It still needs `ssh` and `rsync`, both of
which ship with macOS.

`make dmg` also puts it in one file for release, `dist/OPRivView-Replay-<version>-macOS-<Intel|ARM>.dmg`, with a shortcut to
Applications and a read-me. The version comes from `pubspec.yaml`, and the name says which Mac the release is for: it
defaults to the one that built it, so running `make dmg` on Apple silicon makes an `ARM` release, and
`make dmg ARCH=Intel` the other kind. A release for one kind of Mac is checked at build time, so it never silently
holds the other kind's ffmpeg or server. A first build needs `brew install nasm`.

ffmpeg is built from the official source by `packaging/build_ffmpeg.sh`, holding only what the app uses: decoding H.265
and H.264, encoding through Apple's VideoToolbox, and the file types involved. That makes it LGPL, not GPL, so it can be
given away, with no libraries beside it. If the app starts asking ffmpeg for something new, add it to the list in that
script. The licences and the ffmpeg source travel in the app, in `Contents/Resources/licenses`
(`packaging/write_notices.py`).

Limits of the release file:
- macOS 14 or later, which is what the bundled numpy needs. The `Intel` and `ARM` releases are for that kind of Mac.
- It is ad-hoc signed and not notarized, as that needs a paid Apple Developer account. macOS refuses it the first time
  and the user allows it once in System Settings, Privacy & Security. The read-me in the disk image explains this.

## Where files come from, and how much detail

Drives are listed from the comma (over SSH) and from comma Connect (the token in `~/.comma/jwt`) together. A drive
on the comma gets full detail: the complete log and camera video, so the path, lane lines and lead markers appear.
A drive that exists only on Connect gets quick detail: Connect keeps just the small files (qlog and qcamera), which
have no path or lane data and a low resolution picture, but the speed, assist state, clock, road name, speed limit
and steering readouts all work. `--detail full|quick|auto` chooses (auto means full when it can be had); quick can
also be used on the comma for a fast draft. Connect never has the wide camera, so quick detail is road camera only.

## Wide camera

`--camera auto` follows the app: in experimental mode the wide camera is shown below 10 m/s and the road camera
above 15 m/s, keeping the current one in between (`replay/oprivview_replay/camera.py`, mirroring
`ConnectionManager._switchStreamIfNeeded`). `road` and `wide` force one camera. The live app takes a second or two to
reconnect when it switches; the replay switches at once. Auto has not yet been seen on a real experimental mode
drive, because none of the drives on the comma had it on; `--camera wide` has been checked against a normal drive.

## Adding an option

Add one `Param` to `oprivview_replay/params.py`. If the renderer needs it, read it in `lib/replay/replay_job.dart`.

## Keeping up with the comma

`oprivview_replay/vendor/` holds the comma's log schemas and slimming code. After they change on dys-a:

```bash
replay/.venv/bin/python replay/tools/sync_vendor.py /path/to/openpilot--dys-a
```

## Tests

```bash
cd replay && .venv/bin/python -m pytest tests
flutter test test/replay_test.dart
```

## App settings

The gear above the drive list opens the app's settings: which device on the comma account to use, the comma's address on the
local network (with a search of the networks this Mac is on), SSH setup, the comma Connect token, the folder clips are saved
in, and how much the stored drives take up, with a button to clear them. Choices are kept in
`~/Library/Application Support/OPRivViewReplay/settings.json`. The token stays in `~/.comma/jwt`, readable only by this user.
Stored drives are in `~/Library/Caches/OPRivViewReplay`. Stalls of 200 ms or more are noted in
`~/Library/Logs/OPRivViewReplay/preview.log`.

## Other people's public drives

Paste a comma Connect link, `device/route`, or a device id on its own into the box above the drive list; a device id adds all
of that device's public drives. No token is needed. Connect rarely has their full camera files, so these usually play as
**Log and small video**: the complete log, so path and lane lines are drawn, over the small video.

## In the preview

Click or drag along the progress bar to go to that part of the clip. It takes a second or two, and the Detailed graphs start
again from there. Speed runs from 0.25x to 4x. Above 1x, frames are skipped if they cannot be drawn in time. The full screen
button leaves only the picture and controls; Esc comes back. Swipes, taps and the settings screen update the option form.

## Why the Mac app does not use Impeller

`FLTEnableImpeller` is off in `macos/Runner/Info.plist`. Flutter ties Impeller to the integrated GPU on Macs with two, and on
an Intel MacBook Pro it reached 2.3 GB against that chip's 1.5 GB budget and hung it. macOS then restarted the chip, which
wiped the app's text and video from it until the app was reopened. Skia peaked at 359 MB on the same drive. It still runs on
the integrated GPU. This setting is for the Mac app only.

## Credits

Town names come from [GeoNames](https://www.geonames.org), used under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). `packaging/build_places.py` rebuilds the list.
