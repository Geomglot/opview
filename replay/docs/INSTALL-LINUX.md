# Installing GeoRivView Replay on Linux

GeoRivView Replay plays back a drive as it looked on the GeoRivView screen, and saves it as an MP4.

This is an early test version of the Linux app. For how to use it, see the [user guide](USER_GUIDE.md), which covers
the Mac, Windows and Linux and notes where they differ.

## What you need

- A 64-bit PC (x86_64) with a desktop: Ubuntu 22.04 or later, Debian 12, Fedora 36 or later, Linux Mint 21 or later,
  or another distribution of the same age or newer. ARM computers, such as a Raspberry Pi, are not supported yet.
- About 300 MB of disk space for the app, and more for the drives you open. A minute of full detail drive takes about
  75 MB, and more with the wide camera. You can clear stored drives from the app.
- To make MP4s, one of these:
  - an NVIDIA graphics card with NVIDIA's own driver (version 520 or later), or
  - Intel or AMD graphics with its VA-API driver. Most distributions install it with the desktop; if not, it is
    `intel-media-va-driver` (newer Intel) or `mesa-va-drivers` (AMD) on Ubuntu, Debian and Mint.
  - Without either, as in most virtual machines, your distribution's own ffmpeg does the encoding instead. Install it
    with `sudo apt install ffmpeg` (Ubuntu, Debian, Mint) or `sudo dnf install ffmpeg` (Fedora, after enabling RPM
    Fusion). The app tells you if it finds no way to encode.

You do not need Python or anything else installed. The app brings its own small ffmpeg for everything else.

## Install

1. Download `GeoRivView-Replay-<version>-Linux-x86_64.AppImage` from the
   [releases page](https://github.com/Geomglot/opview/releases). Test versions are marked Pre-release, and their names
   start with `replay-`.
2. Move it where you keep programs, for example a folder called `Applications` in your home folder. Keep it somewhere
   you can change, so the app can update itself there.
3. Make it runnable, once: right-click it, choose **Properties**, then **Permissions**, and tick **Allow executing file
   as program** (the wording differs a little between desktops). Or in a terminal:

   ```sh
   chmod +x ~/Applications/GeoRivView-Replay-*-Linux-x86_64.AppImage
   ```

4. Double-click it to open it.

The AppImage is the whole app: nothing else is installed. To have it in your desktop's app menu, use a tool such as
Gear Lever or AppImageLauncher, which add AppImages to the menu for you.

If you would like to check the download first, each release lists the checksums of its files in `SHA256SUMS`. To see
yours:

```sh
sha256sum ~/Applications/GeoRivView-Replay-*-Linux-x86_64.AppImage
```

## Reaching your comma

Drives from comma Connect, and public drives you paste in, need nothing more. To open drives straight from your comma
over your local network, the app uses your computer's own SSH (`ssh` and `scp`), which almost every desktop
distribution has. If `rsync` is installed too, the app uses it to copy, as on the Mac; without it, it copies with `scp`.
Set up the comma in App settings as the [user guide](USER_GUIDE.md) describes. **Create a key** makes the key in your
`~/.ssh` folder.

If SSH is missing, reaching the comma fails with an error saying `ssh` was not found. Install it with
`sudo apt install openssh-client` (Ubuntu, Debian, Mint) or `sudo dnf install openssh-clients` (Fedora).

## Updating

The app offers new versions itself: see Updates in the [user guide](USER_GUIDE.md#updates). It downloads the new
AppImage, puts it in place of the one you opened, and reopens. The file keeps its old name, so shortcuts to it keep
working; the version you have is at the bottom of the app's **?** menu. If the AppImage is in a folder your account
cannot change, the app shows you the download instead, to move into place yourself.

You can also download the new AppImage yourself, make it runnable as above, and delete the old one. Your settings and
stored drives are kept, because they are not in the AppImage.

## Removing it

Delete the AppImage. Your settings and the drives the app stored are in these folders, which you can delete too:

- `~/.config/GeoRivViewReplay` (settings)
- `~/.cache/GeoRivViewReplay` (stored drives, which include your video and GPS positions)
- `~/.local/state/GeoRivViewReplay` (logs)

Clips you saved stay in your Videos folder, or wherever you chose. Your comma Connect token is in `~/.comma/jwt`. Other
comma tools use that file too, so delete it only if nothing else needs it.

## Differences from the Mac

The [user guide](USER_GUIDE.md) notes each one where it comes up: clips go to Videos, **Show in Finder** is **Show in
file manager**, and rendering speed on a real Linux PC has not been measured yet. Please tell us how long it takes on
yours. In a virtual machine with no graphics card, rendering is much slower, because the drawing is done by the
processor.

## If something goes wrong

- **Nothing happens when you double-click it.** It is not runnable yet: see step 3. Some file managers open runnable
  files in a text editor; then right-click it and choose **Run**, or start it from a terminal to see any message.
- **It says FUSE is missing, or it cannot mount.** Start it with `--appimage-extract-and-run` after its name in a
  terminal. To fix it for good, install your distribution's FUSE package (`fuse3` on most).
- **Rendering fails with a message about the video encoder.** Install your distribution's ffmpeg, as above, or update
  your graphics driver.
- **Reaching the comma fails because `ssh` was not found.** Install SSH, as above.
- **The app says the replay server did not start.** Close it and open it again. If that does not help, please report it.

To report a problem, use the [issues page](https://github.com/Geomglot/opview/issues) and say which version of the app
(at the bottom of its **?** menu) and which distribution and version you have, your graphics card, and what you were
doing. Starting the AppImage from a terminal shows messages that help. Check screenshots before you post them, because
they can show licence plates.
