# GeoRivView Replay user guide

GeoRivView Replay was called OPRivView Replay until November 2026. Only the name has changed: an update keeps your settings
and stored drives.

GeoRivView Replay redraws a drive as it looked on the GeoRivView screen: the camera picture with the speed, path, lane lines
and panels on top. You can watch it in the app and save any part of it as an MP4. It draws from the drive's logs, using the
same screen layouts as the GeoRivView app, so you can also choose a different view from the one you had in the car.

The app runs on Macs, Windows PCs and Linux PCs and works the same way on all of them. Where they differ, this guide
says so. To install it, see the install guide for the [Mac](INSTALL.md), [Windows](INSTALL-WINDOWS.md) or
[Linux](INSTALL-LINUX.md). This is an early test version.

The **?** button above the drive list opens this guide and the install guide.

GeoRivView Replay is an independent project. It is not made or endorsed by comma.ai. It uses your own comma Connect sign-in,
and for reaching the comma away from home, your own comma prime subscription.

## Getting your drives into the app

The app can read drives from four places. You only need one.

| Source | What you need | What you get |
| --- | --- | --- |
| Your comma, over your local network | The comma on the same network as your computer, and SSH set up | Full detail, while the drive is still on the comma |
| comma Connect | A comma Connect token | Whatever Connect keeps, usually the small files |
| Your comma, through comma's server | comma prime, a Connect token, SSH set up, and the comma online | Full detail, when the comma is not on your network |
| Other people's public drives | Nothing but a link | Usually the log and small video |

The gear above the drive list opens **App settings**, where you set up the first two.

### Connecting to your comma

1. In App settings, press **Find on this network**, or type the comma's address under **Address or SSH name**.
2. Press **Test and use**.
3. If this computer has no SSH key, press **Create a key**. On Windows the key goes in `C:\Users\<you>\.ssh`, and the app
   uses Windows' own SSH. If Windows reports that it cannot find the file specified, add **OpenSSH Client** as the
   [Windows install guide](INSTALL-WINDOWS.md#reaching-your-comma) describes. On Linux it goes in `~/.ssh`, and the app
   uses your computer's own SSH; the [Linux install guide](INSTALL-LINUX.md#reaching-your-comma) says what to install if
   it is missing.
4. If the comma does not let your computer in, copy the key and add it at github.com under Settings, SSH and GPG keys. **Open GitHub
   SSH keys** takes you there. Then on the comma open Settings, Developer, turn on Enable SSH, and enter your GitHub username
   under SSH Keys. Press **Test and use** again.

### Connecting to comma Connect

1. In App settings, press **Get a token** and sign in. This opens comma's token page.
2. Paste the token under **New token** and press **Save**.

If you have more than one device on your account, you can choose which one to use. Tokens expire. The app tells you when it
needs a new one.

### When the comma is not on your network

With comma prime, the app can copy full detail from your comma through comma's own SSH server, wherever the comma is, as
long as it is online. It uses the same SSH key as on your network, so set that up first. The app only does this when the
comma does not answer on your network, and only for files Connect does not already have. The status line counts the
megabytes as they arrive: about 90 MB for each minute of drive, or 165 MB with the wide camera.

This uses the comma's own internet connection. First the app asks the comma what it is connected to.
- If the comma treats its connection as unmetered (its own **Wi-Fi Network Metered** and **Cellular Metered**
  settings), the app copies straight away.
- If the connection is metered, or the comma does not say, the app asks you first and shows the size.
  - **Copy now** goes ahead.
  - **Not now** uses what comma Connect has, which is usually less detail. With **Full** detail chosen, it stops instead.

To stop the app doing this at all, turn off **Reach the comma through comma's server** in App settings.

#### A copy on comma Connect for later

With the comma away from your network, the app also asks it to upload the full files of the range to comma Connect, so
they are there later, when the comma is offline or has deleted the drive. It does this after copying them from the comma
through comma's server. It also does it when it cannot get full detail now: the comma is offline, you chose **Not now**,
or you do not have comma prime.
- **Only what Connect lacks.** It asks only for the range you chose, plus the segment before it, never the whole drive, and
  not again within 7 days.
- **The comma decides when.** It uploads only on a connection it treats as unmetered. If it is offline, comma keeps the
  request for 7 days and gives it to the comma when it is back.
- **The drive pane shows how it is going.** For example, "Upload to comma Connect: 1 of 3 files there", or "The comma is
  waiting for an unmetered connection". When all the files are there, the drive is listed again with what Connect now has.

Connect keeps uploaded files for 1 year with comma prime, and 3 days without. To stop these uploads, turn off **Keep a
copy on comma Connect** in App settings.

### Adding a public drive

Paste a comma Connect link, `device/route`, or a device id into the box above the drive list, and press **Add**. A device id
adds all of that device's public drives. To take one off the list, use **Remove from the list**.

### Finding a drive

Press **Filters**, under the box for adding a drive, to narrow the list. Each filter you leave empty lets every drive
through. The button shows how many filters are set, and the count of drives shown is beside it. Filters keep working
while the panel is hidden. **Clear all** removes every filter.

| Filter | Shows drives |
| --- | --- |
| **Date** | Started on a day in the range, in the drive's own time. Pick one day, or a first and last day |
| **Starts in**, **Ends in** | Starting or ending in a town whose name contains what you type, such as `toron` |
| **Length** | With this many segments (minutes), from the first number to the second. Leave one end empty for no limit |
| **Distance** | This long, in km or miles as your comma is set |
| **Available from** | On the comma, on comma Connect, or already on this computer, so they play without fetching anything. Tick more than one for drives in any of them |
| **Detail** | With the full camera video, or with only the small video |
| **Time of day** | Started between sunrise and sunset (**Day**) or after dark (**Night**) where the drive was |
| **Drives** | Yours, or public drives you added by hand |

The towns, distance and time of day come from comma Connect, which has nearly every drive, as the comma uploads its small
logs. A drive only on the comma has its date from the comma's files, accurate to about a minute, and its time of day once
the app has read its logs (after **Check range** or a preview), but no towns or distance. A filter leaves out drives it
cannot tell about: with a town set, for example, a drive with no known town is not shown.

## Choosing what to play

1. Pick a drive from the list on the left.
2. Choose a **Start** and **End**. Each is a **Segment** number unless you switch it to a **Time** of day, written as
   HH:MM:SS. A segment is one minute of driving, and the empty field shows which segments the drive has, such as `0-12`.
   A segment start begins at the start of that segment, and a segment end finishes at its end. For a cut part-way through
   a minute, use Time. Times are local to where the drive happened. Where the app cannot tell the place, it uses your
   computer's time zone and says so.
3. Press **Check range** to confirm what you have selected. The first time you check a drive, the app copies a small
   log of every segment of it, to find its times and places. For a long drive that can take a while: it shows the time
   left, and **Cancel** stops it (see [Fetching the files](#fetching-the-files)).

## Options

| Option | Choices |
| --- | --- |
| View | Classic, Enhanced or Detailed, the same layouts as in the GeoRivView app |
| Bottom bar | App default, Torque bar, Lane keeping, Automatic or Off |
| Detail | How much of the drive to use, explained below |
| Camera | Automatic, road or wide. Automatic follows the app, which uses the wide camera at low speed in experimental mode |
| Collapsed panels | Detailed view only: which panels to fold shut |
| Clock | 12 or 24 hour |
| Speed limit | Automatic, Always or Off |
| Road name | Show or Hide |

**Advanced** holds the size of the MP4, the size of the camera picture and the bitrate. The defaults are 1920 by 1080 at 8M.

### Detail

- **Full detail** uses the complete log and full camera video. It is the best, and needs the drive to be on your comma.
- **Log and small video** draws the path and lane lines over a lower resolution picture. Public drives usually play this way.
- **Quick detail** uses only the small files, so there is no path or lane lines, but the speed, assist state, clock, road name
  and steering readouts still work. Connect-only drives usually play this way.
- **Automatic** uses the best the drive has.

The wide camera is only available in full detail.

## Fetching the files

Before it can check, preview or render a range, the app copies what it needs to your computer, from the comma or
comma Connect: first a small log of every segment of the drive, then the video and logs of the range. It keeps what it
has copied, so the same drive is quicker the next time.

- If either copy needs many segments that are not on your computer yet, the app asks first, and says how much that is
  when it can tell. Press **Fetch** to go ahead, or **Cancel**, for example if you left **End** empty by mistake and the
  range is the whole drive.
- How many is "many" is set in App settings, under **Long fetches**: 5 segments or more from comma Connect or through
  comma's server, and 30 or more from the comma on your network, which copies much faster. 0 means never ask.
- While it fetches, the line under the progress bar shows how much has arrived and about how long the rest will take.
  The time left follows how fast the files have come over the last half minute, so it settles after the first few
  seconds.
- **Cancel** asks whether to stop. **Keep fetching** carries on, in case Cancel was pressed by mistake. **Stop
  fetching** stops. Either way, the files that have arrived stay on your computer, so fetching that range again carries
  on from there.

## Previewing

Press **Preview** to play the range in the window.

- **Play**, **Pause** and **Restart** do what they say.
- Under the picture, the app shows how far into the clip you are, and which segment of the drive that is and how far into
  it, such as `segment 4, 0:15`. Use that segment number in **Start** or **End**.
- Click or drag along the progress bar to go to that part of the clip. It takes a second or two, and the graphs in the Detailed
  view start again from there.
- **Playback speed** runs from 0.25x to 4x. Above 1x, frames may be skipped.
- **Full screen** leaves only the picture and controls. Press Esc to come back.
- **Settings** opens the GeoRivView settings screen. You can also press and hold the picture for about half a second.
- Swipes and taps work as they do in the GeoRivView app, and any change they make also shows in the options.

## Saving an MP4

Press **Render MP4**. Progress stays in the window, and you can carry on using your computer. Rendering takes longer than
the drive itself: about 2 minutes for each minute of drive on the Mac it was tested on. Windows has not been timed on a real
PC yet; in a virtual machine with no graphics card it took about 3.5 minutes per minute of drive. Linux has not been
timed on a real PC yet either; with no graphics card, as in most virtual machines, it is much slower, because the
processor does the drawing.

- While it renders, the preview area shows the frame it has reached, updated about once a second, and the line under the
  progress bar says which segment and how far into it.
- Clips go to your Movies folder on a Mac, or your Videos folder on Windows and Linux, unless you pick a different folder in App
  settings, or an **Output file** with **Choose...**.
- **Cancel** asks what to do with the part made so far, and shows how much that is:
  - **Save what's done** finishes the clip where the render has got to, and saves it with "(partial)" added to its
    name. It never replaces an earlier clip.
  - **Discard** stops and saves nothing.
  - **Keep rendering** carries on, in case Cancel was pressed by mistake. The render keeps going while you decide.

  Cancel while the files are still coming asks whether to stop fetching (see [Fetching the files](#fetching-the-files)).
  After that, Cancel before the first frames are made, or during a preview, just stops.
- Otherwise a clip is only saved once it is complete.
- The app does not replace an earlier clip when it picks the name itself. If you choose or type a file name, it does.
- When the render is done, use **Play** to open the clip, or **Show in Finder** (**Show in Explorer** on Windows, **Show
  in file manager** on Linux).

## Stored drives

Drives you open are kept on your computer so they open faster next time. They can get large, and there is no automatic limit yet.
They also include your camera video and GPS positions. **Clear stored drives** in App settings removes them, and shows how
much space they take. Your saved clips are not touched.

## Updates

From version 0.1.2, the app checks for a newer version when it opens, and **Check for updates** in the **?** menu checks
again. When there is one, it shows what is new and offers **Update**; **Later** leaves it for now. It does not update
while a render or preview is running.

- On Windows, Update downloads the new installer, closes the app, installs the new version and opens it again.
- On a Mac, Update downloads the new version, closes the app, puts the new version in place of the old one and opens
  it again. If the app cannot change the folder it is in, it shows the downloaded disk image in the Finder instead, to
  drag the new app over the old one. The [install guide](INSTALL.md#updating) has more.
- On Linux, Update downloads the new AppImage, puts it in place of the one you opened (keeping its name, so shortcuts
  still work), and opens it. If the app cannot change the folder the AppImage is in, it shows the download instead. The
  [Linux install guide](INSTALL-LINUX.md#updating) has more.

Test versions are offered as well as final ones unless you turn off **Include test versions** under Updates in App
settings. Your settings and stored drives are kept. The **?** menu also shows which version you have.

## Known limits in this version

- A drive deleted from the comma is available only as what Connect kept. The full files are on Connect only if they were
  uploaded before the comma deleted them (see [A copy on comma Connect for later](#a-copy-on-comma-connect-for-later)).
- The app cannot read logs you have already copied to your computer yet.
- About one drive in six has no position from Connect, so it shows no town name unless its logs are already stored.
- The Automatic wide camera rule has not yet been checked on a real experimental mode drive.
- The GeoRivView app takes a second or two to change cameras while driving. The replay changes at once.
- Public drives from other forks of openpilot may not decode.
- The Linux version is new and has not yet been tried on a real Linux PC with a graphics card. In a virtual machine the
  preview can be jerky: the processor decodes the video, and with 4 cores it only just keeps up. More cores help.
