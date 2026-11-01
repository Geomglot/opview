# OPRivView replay

Renders a drive as an MP4 of the OPRivView screen. The real onroad layouts draw the drive, fed the same messages
the comma sent the app live, so the result looks as it did in the car.

Currently a command-line tool that fetches from the comma over SSH. The desktop interface and packaged app come next.
The full plan is in `OpenpilotTools/plans/oprivview-replay-mac-app.md`.

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
There is no in-window preview yet; Play opens the finished MP4.

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
