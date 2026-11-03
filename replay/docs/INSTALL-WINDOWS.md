# Installing OPRivView Replay on Windows

OPRivView Replay plays back a drive as it looked on the OPRivView screen, and saves it as an MP4.

This is an early test version of the Windows app. For how to use it, see the [user guide](USER_GUIDE.md), which covers
the Mac and Windows and notes where they differ.

## What you need

- 64-bit Windows 10 or 11.
- About 200 MB of disk space for the app, and more for the drives you open. A minute of full detail drive takes about
  75 MB, and more with the wide camera. You can clear stored drives from the app.
- To make MP4s: a graphics card from NVIDIA, Intel or AMD, or Windows' own video encoder. Windows has that encoder
  unless it is an "N" edition. On an N edition, install the Media Feature Pack from Settings, Apps, Optional features.

You do not need Python, ffmpeg or anything else installed.

## Install

1. Download `OPRivView-Replay-<version>-Windows.zip` from the
   [releases page](https://github.com/Geomglot/opview/releases). Test versions are marked Pre-release, and their names
   start with `replay-`. If your browser warns that the file is not commonly downloaded, choose to keep it.
2. Right-click the zip and choose **Extract All...**. Extract it somewhere with a short path, such as Documents or the
   Desktop. Windows cannot open files buried too many folders deep, so a long path may make the extraction fail.
3. Open the **OPRivView Replay** folder and double-click **OPRivViewReplay.exe**.

Nothing else is installed. To start the app from the Start menu or the taskbar, right-click **OPRivViewReplay.exe** and
choose **Pin to Start**, or **Show more options** then **Pin to taskbar**.

Keep the files in the folder together. The app needs the `ffmpeg`, `oprivview-replay-server` and `data` folders beside it.

## The first time you open it

The app is not signed, so Windows SmartScreen may stop it with "Windows protected your PC". This is a one-time step:

1. Click **More info**.
2. Click **Run anyway**.

The app opens, and from then on it opens normally.

If you would like to check the download first, each release lists the file's SHA-256 checksum. To see yours, run this in
PowerShell:

```powershell
Get-FileHash "$HOME\Downloads\OPRivView-Replay-*-Windows.zip" -Algorithm SHA256
```

## Reaching your comma

Drives from comma Connect, and public drives you paste in, need nothing more. To open drives straight from your comma
over your local network, the app uses Windows' own SSH, which Windows 10 and 11 normally have. Set it up in App settings
as the [user guide](USER_GUIDE.md) describes. **Create a key** makes the key in your `.ssh` folder, in
`C:\Users\<you>\.ssh`.

If SSH is missing, reaching the comma fails with an error saying the system cannot find the file specified. Then open
Settings, Apps, Optional features, choose **Add a feature** (or **View features**), and add **OpenSSH Client**.

## Updating

Close the app, delete the old **OPRivView Replay** folder, and extract the new version in the same way. You may need to
do the SmartScreen step again. Your settings and stored drives are kept, because they are not in the app's folder.

## Removing it

Delete the **OPRivView Replay** folder. To remove everything it stored as well, delete these. You can paste each one into
the address bar of File Explorer:

- `%APPDATA%\OPRivViewReplay` (settings)
- `%LOCALAPPDATA%\OPRivViewReplay` (stored drives, which include your video and GPS positions, and logs)

Clips you saved stay in your Videos folder, or wherever you chose. Your comma Connect token is in
`%USERPROFILE%\.comma\jwt`. Other comma tools use that file too, so delete it only if nothing else needs it.

## Differences from the Mac

The [user guide](USER_GUIDE.md) notes each one where it comes up: clips go to Videos, **Show in Finder** is **Show in
Explorer**, and rendering speed on a real PC has not been measured yet. Please tell us how long it takes on yours.

## If something goes wrong

- **There is no Run anyway button.** Click **More info** first. If your PC is managed by an employer or school, its
  settings may not allow unsigned programs.
- **Extracting fails, or the app cannot find a file.** Extract it to a shorter path, such as straight into Documents.
- **Reaching the comma fails because the system cannot find the file specified.** SSH is missing. Add OpenSSH Client,
  as above.
- **Rendering fails with a message about the video encoder.** Update your graphics driver. On an N edition of Windows,
  install the Media Feature Pack.
- **The app says the replay server did not start.** Close it and open it again. If that does not help, please report it.

To report a problem, use the [issues page](https://github.com/Geomglot/opview/issues) and say which version of the app and of
Windows you have, your graphics card, and what you were doing. Check screenshots before you post them, because they can
show licence plates.
