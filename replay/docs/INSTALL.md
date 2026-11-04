# Installing OPRivView Replay

OPRivView Replay is a Mac app that plays back a drive as it looked on the OPRivView screen, and saves it as an MP4.

This is an early test version. For how to use it, see the [user guide](USER_GUIDE.md).

## What you need

- A Mac with macOS 14 or later. Each release is for one kind of Mac; pick the one that matches yours:
  `...-macOS-Intel.dmg` for an Intel Mac, `...-macOS-ARM.dmg` for Apple silicon (an M-series Mac).
- About 200 MB of disk space for the app, and more for the drives you open. A minute of full detail drive takes about
  75 MB, and more with the wide camera. You can clear stored drives from the app.

You do not need Python, ffmpeg or anything else installed.

## Install

1. Download the `OPRivView-Replay-<version>-macOS-<Intel|ARM>.dmg` for your Mac (Intel or Apple silicon) from the
   [releases page](https://github.com/Geomglot/opview/releases). Test versions are marked Pre-release, and their names start
   with `replay-`.
2. Open the file. A disk called OPRivView Replay appears.
3. Drag **OPRivView Replay** onto the **Applications** folder.
4. Eject the disk.

Run the app from Applications, not from the disk.

## The first time you open it

The app is not notarized by Apple, so macOS refuses to open it at first. It says "OPRivView Replay.app" Not Opened, and that
Apple could not verify it is free of malware. This is a one-time step:

1. Open the app from Applications. When the message appears, click **Done**. Do not click Move to Trash.
2. Open **System Settings**, then **Privacy & Security**, and scroll down to the **Security** section.
3. Click **Open Anyway** beside OPRivView Replay, then confirm with your password or Touch ID.

The app opens, and from then on it opens normally.

If you would like to check the download first, each release lists the file's SHA-256 checksum. To see yours, run this in
Terminal:

```bash
shasum -a 256 ~/Downloads/OPRivView-Replay-*.dmg
```

## Updating

Quit the app, then install the new version in the same way and choose to replace the old one. You may need to do the Open
Anyway step again. Your settings and stored drives are kept.

## Removing it

Drag the app from Applications to the Trash. To remove everything it stored as well, delete these:

- `~/Library/Application Support/OPRivViewReplay` (settings)
- `~/Library/Caches/OPRivViewReplay` (stored drives, which include your video and GPS positions)
- `~/Library/Logs/OPRivViewReplay` (logs)

Clips you saved stay in your Movies folder, or wherever you chose. Your comma Connect token is in `~/.comma/jwt`. Other
comma tools use that file too, so delete it only if nothing else needs it.

## If something goes wrong

- **There is no Open Anyway button.** Try opening the app once more, then look again. The button only stays for a while
  after the app is refused.
- **macOS says the app needs a newer version of macOS.** You need macOS 14 or later.
- **The app says the replay server did not start.** Quit it and open it again. If that does not help, please report it.

To report a problem, use the [issues page](https://github.com/Geomglot/opview/issues) and say which version of the app
(at the bottom of its **?** menu) and of macOS you have, and what you were doing. Check screenshots before you post
them, because they can show licence plates.