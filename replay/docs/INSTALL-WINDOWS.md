# Installing GeoRivView Replay on Windows

GeoRivView Replay plays back a drive as it looked on the GeoRivView screen, and saves it as an MP4.

This is an early test version of the Windows app. For how to use it, see the [user guide](USER_GUIDE.md), which covers
the Mac and Windows and notes where they differ.

## What you need

- 64-bit Windows 10 or 11.
- About 250 MB of disk space for the app, and more for the drives you open. A minute of full detail drive takes about
  75 MB, and more with the wide camera. You can clear stored drives from the app.
- To make MP4s: a graphics card from NVIDIA, Intel or AMD, or Windows' own video encoder. Windows has that encoder
  unless it is an "N" edition. On an N edition, install the Media Feature Pack from Settings, Apps, Optional features.

You do not need Python, ffmpeg or anything else installed.

## Install

1. Download `GeoRivView-Replay-<version>-Windows.exe` from the
   [releases page](https://github.com/Geomglot/opview/releases). Test versions are marked Pre-release, and their names
   start with `replay-`. If your browser warns that the file is not commonly downloaded, choose to keep it.
2. Open it. The installer is not signed, so Windows SmartScreen may stop it with "Windows protected your PC". Click
   **More info**, then **Run anyway**.
3. Follow the installer. It installs for you only, in your own folder, so it does not ask for an administrator. You can
   choose to add a desktop shortcut. At the end it can open the app.

The app is then in the Start menu as **GeoRivView Replay**. To pin it to the taskbar, right-click it there and choose
**Pin to taskbar**.

If you would like to check the download first, each release lists the checksums of its files in `SHA256SUMS`. To see
yours, run this in PowerShell:

```powershell
Get-FileHash "$HOME\Downloads\GeoRivView-Replay-*-Windows.exe" -Algorithm SHA256
```

## Reaching your comma

Drives from comma Connect, and public drives you paste in, need nothing more. To open drives straight from your comma
over your local network, the app uses Windows' own SSH, which Windows 10 and 11 normally have. Set it up in App settings
as the [user guide](USER_GUIDE.md) describes. **Create a key** makes the key in your `.ssh` folder, in
`C:\Users\<you>\.ssh`.

If SSH is missing, reaching the comma fails with an error saying the system cannot find the file specified. Then open
Settings, Apps, Optional features, choose **Add a feature** (or **View features**), and add **OpenSSH Client**.

## Updating

From version 0.1.2 the app offers new versions itself: see Updates in the [user guide](USER_GUIDE.md#updates). You can
also download the new installer and open it, as above. Either way it replaces the old version, closing the app first if
it is open. Your settings and stored drives are kept, because they are not in the app's folder.

## Removing it

Open Settings, Apps, find **GeoRivView Replay**, and choose **Uninstall**. It asks whether to delete your settings and
the drives the app stored as well. Those are in these folders, which you can also delete yourself by pasting each one
into the address bar of File Explorer:

- `%APPDATA%\GeoRivViewReplay` (settings)
- `%LOCALAPPDATA%\GeoRivViewReplay` (stored drives, which include your video and GPS positions, and logs)

Clips you saved stay in your Videos folder, or wherever you chose. Your comma Connect token is in
`%USERPROFILE%\.comma\jwt`. Other comma tools use that file too, so delete it only if nothing else needs it.

Versions before 0.1.2 came as a zip with no installer. If you used one, delete its **GeoRivView Replay** folder.

## Differences from the Mac

The [user guide](USER_GUIDE.md) notes each one where it comes up: clips go to Videos, **Show in Finder** is **Show in
Explorer**, and rendering speed on a real PC has not been measured yet. Please tell us how long it takes on yours.

## If something goes wrong

- **There is no Run anyway button.** Click **More info** first. If your PC is managed by an employer or school, its
  settings may not allow unsigned programs.
- **Reaching the comma fails because the system cannot find the file specified.** SSH is missing. Add OpenSSH Client,
  as above.
- **Rendering fails with a message about the video encoder.** Update your graphics driver. On an N edition of Windows,
  install the Media Feature Pack.
- **The app says the replay server did not start.** Close it and open it again. If that does not help, please report it.

To report a problem, use the [issues page](https://github.com/Geomglot/opview/issues) and say which version of the app
(at the bottom of its **?** menu) and of Windows you have, your graphics card, and what you were doing. Check
screenshots before you post them, because they can show licence plates.