# OPRivView Replay user guide

OPRivView Replay redraws a drive as it looked on the OPRivView screen: the camera picture with the speed, path, lane lines
and panels on top. You can watch it in the app and save any part of it as an MP4. It draws from the drive's logs, using the
same screen layouts as the OPRivView app, so you can also choose a different view from the one you had in the car.

The app runs on Macs and on Windows PCs and works the same way on both. Where they differ, this guide says so. To install
it, see the install guide for the [Mac](INSTALL.md) or for [Windows](INSTALL-WINDOWS.md). This is an early test version.

The **?** button above the drive list opens this guide and the install guide.

## Getting your drives into the app

The app can read drives from three places. You only need one.

| Source | What you need | What you get |
| --- | --- | --- |
| Your comma, over your local network | The comma on the same network as your computer, and SSH set up | Full detail, while the drive is still on the comma |
| comma Connect | A comma Connect token | Whatever Connect keeps, usually the small files |
| Other people's public drives | Nothing but a link | Usually the log and small video |

The gear above the drive list opens **App settings**, where you set up the first two.

### Connecting to your comma

1. In App settings, press **Find on this network**, or type the comma's address under **Address or SSH name**.
2. Press **Test and use**.
3. If this computer has no SSH key, press **Create a key**. On Windows the key goes in `C:\Users\<you>\.ssh`, and the app
   uses Windows' own SSH. If Windows reports that it cannot find the file specified, add **OpenSSH Client** as the
   [Windows install guide](INSTALL-WINDOWS.md#reaching-your-comma) describes.
4. If the comma does not let your computer in, copy the key and add it at github.com under Settings, SSH and GPG keys. **Open GitHub
   SSH keys** takes you there. Then on the comma open Settings, Developer, turn on Enable SSH, and enter your GitHub username
   under SSH Keys. Press **Test and use** again.

### Connecting to comma Connect

1. In App settings, press **Get a token** and sign in. This opens comma's token page.
2. Paste the token under **New token** and press **Save**.

If you have more than one device on your account, you can choose which one to use. Tokens expire. The app tells you when it
needs a new one.

### Adding a public drive

Paste a comma Connect link, `device/route`, or a device id into the box above the drive list, and press **Add**. A device id
adds all of that device's public drives. To take one off the list, use **Remove from the list**.

## Choosing what to play

1. Pick a drive from the list on the left.
2. Choose a **Start** and **End**. Each is a **Segment** number unless you switch it to a **Time** of day, written as
   HH:MM:SS. A segment is one minute of driving, and the empty field shows which segments the drive has, such as `0-12`.
   A segment start begins at the start of that segment, and a segment end finishes at its end. For a cut part-way through
   a minute, use Time. Times are local to where the drive happened. Where the app cannot tell the place, it uses your
   computer's time zone and says so.
3. Press **Check range** to confirm what you have selected.

## Options

| Option | Choices |
| --- | --- |
| View | Classic, Enhanced or Detailed, the same layouts as in the OPRivView app |
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

## Previewing

Press **Preview** to play the range in the window.

- **Play**, **Pause** and **Restart** do what they say.
- Under the picture, the app shows how far into the clip you are, and which segment of the drive that is and how far into
  it, such as `segment 4, 0:15`. Use that segment number in **Start** or **End**.
- Click or drag along the progress bar to go to that part of the clip. It takes a second or two, and the graphs in the Detailed
  view start again from there.
- **Playback speed** runs from 0.25x to 4x. Above 1x, frames may be skipped.
- **Full screen** leaves only the picture and controls. Press Esc to come back.
- **Settings** opens the OPRivView settings screen. You can also press and hold the picture for about half a second.
- Swipes and taps work as they do in the OPRivView app, and any change they make also shows in the options.

## Saving an MP4

Press **Render MP4**. Progress stays in the window, and you can carry on using your computer. Rendering takes longer than
the drive itself: about 2 minutes for each minute of drive on the Mac it was tested on. Windows has not been timed on a real
PC yet; in a virtual machine with no graphics card it took about 3.5 minutes per minute of drive.

- While it renders, the preview area shows the frame it has reached, updated about once a second, and the line under the
  progress bar says which segment and how far into it.
- Clips go to your Movies folder on a Mac, or your Videos folder on Windows, unless you pick a different folder in App
  settings, or an **Output file** with **Choose...**.
- **Cancel** asks what to do with the part made so far:
  - **Save what's done** finishes the clip where the render has got to, and saves it with "(partial)" added to its
    name. It never replaces an earlier clip.
  - **Discard** stops and saves nothing.
  - **Keep rendering** carries on, in case Cancel was pressed by mistake. The render keeps going while you decide.

  Cancel before the first frames are made, or during a preview, just stops.
- Otherwise a clip is only saved once it is complete.
- The app does not replace an earlier clip when it picks the name itself. If you choose or type a file name, it does.
- When the render is done, use **Play** to open the clip, or **Show in Finder** (**Show in Explorer** on Windows).

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

Test versions are offered as well as final ones unless you turn off **Include test versions** under Updates in App
settings. Your settings and stored drives are kept. The **?** menu also shows which version you have.

## Known limits in this version

- A drive deleted from the comma is available only as what Connect kept. Requesting the full files back from the comma through
  Connect is not supported.
- The app cannot read logs you have already copied to your computer yet.
- About one drive in six has no position from Connect, so it shows no town name unless its logs are already stored.
- The Automatic wide camera rule has not yet been checked on a real experimental mode drive.
- The OPRivView app takes a second or two to change cameras while driving. The replay changes at once.
- Public drives from other forks of openpilot may not decode.
