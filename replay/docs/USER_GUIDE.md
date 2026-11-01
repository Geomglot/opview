# OPRivView Replay user guide

OPRivView Replay redraws a drive as it looked on the OPRivView screen: the camera picture with the speed, path, lane lines
and panels on top. You can watch it in the app and save any part of it as an MP4. It draws from the drive's logs, using the
same screen layouts as the OPRivView app, so you can also choose a different view from the one you had in the car.

To install the app, see the [install guide](INSTALL.md). This is an early test version.

## Getting your drives into the app

The app can read drives from three places. You only need one.

| Source | What you need | What you get |
| --- | --- | --- |
| Your comma, over your local network | The comma on the same network as the Mac, and SSH set up | Full detail, while the drive is still on the comma |
| comma Connect | A comma Connect token | Whatever Connect keeps, usually the small files |
| Other people's public drives | Nothing but a link | Usually the log and small video |

The gear above the drive list opens **App settings**, where you set up the first two.

### Connecting to your comma

1. In App settings, press **Find on this network**, or type the comma's address under **Address or SSH name**.
2. Press **Test and use**.
3. If this Mac has no SSH key, press **Create a key**.
4. If the comma does not let the Mac in, copy the key and add it at github.com under Settings, SSH and GPG keys. **Open GitHub
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
2. Choose a **Start** and **End**. Each can be a **Segment** number or a **Time** of day, written as HH:MM:SS. A segment is one
   minute of driving. Times are local to where the drive happened. Where the app cannot tell the place, it uses your Mac's
   time zone and says so.
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
- Click or drag along the progress bar to go to that part of the clip. It takes a second or two, and the graphs in the Detailed
  view start again from there.
- **Playback speed** runs from 0.25x to 4x. Above 1x, frames may be skipped.
- **Full screen** leaves only the picture and controls. Press Esc to come back.
- **Settings** opens the OPRivView settings screen. You can also press and hold the picture for about half a second.
- Swipes and taps work as they do in the OPRivView app, and any change they make also shows in the options.

## Saving an MP4

Press **Render MP4**. Progress stays in the window, and you can carry on using your Mac. Rendering takes longer than the
drive itself: about 2 minutes for each minute of drive on the Intel Mac it was tested on.

- Clips go to your Movies folder unless you pick a different folder in App settings, or an **Output file** with **Choose...**.
- A clip is only saved if it is complete. **Cancel** stops the render and saves nothing.
- The app does not replace an earlier clip when it picks the name itself. If you choose or type a file name, it does.
- When the render is done, use **Play** to open the clip, or **Show in Finder**.

## Stored drives

Drives you open are kept on the Mac so they open faster next time. They can get large, and there is no automatic limit yet.
They also include your camera video and GPS positions. **Clear stored drives** in App settings removes them, and shows how
much space they take. Your saved clips are not touched.

## Known limits in this version

- A drive deleted from the comma is available only as what Connect kept. Requesting the full files back from the comma through
  Connect is not supported.
- The app cannot read logs you have already copied to the Mac yet.
- About one drive in six has no position from Connect, so it shows no town name unless its logs are already stored.
- The Automatic wide camera rule has not yet been checked on a real experimental mode drive.
- The OPRivView app takes a second or two to change cameras while driving. The replay changes at once.
- Public drives from other forks of openpilot may not decode.
- There is no automatic update. New versions are on the [releases page](https://github.com/Geomglot/opview/releases).
