# OPRivView user guide

OPRivView shows your comma device's driving screen live on an Android phone, tablet or car head
unit, including the EV Play box that puts Android on a Rivian's center screen. You see the road
camera with the openpilot / sunnypilot overlay on top: the planned path, lane lines, lead car,
speeds, alerts and the status of steering and cruise control.

It only watches. Nothing you do in OPRivView changes how the car drives or any setting on the comma.

This guide covers version 0.1.2-rivian.4.

## What you need

- **A comma device** (comma 3X or comma four) running a build that streams to OPRivView. Geomglot's
  sunnypilot build does (Geomglot/openpilot, branch `dys-a`). Other openpilot and sunnypilot builds
  work if their streaming service runs while driving; see the README. Some readouts, such as
  lane centering, need Geomglot's build.
- **An Android device** running Android 7.0 or later: a phone, a tablet, a head unit, or the
  EV Play Max in a Rivian.
- **One network for both.** The comma and the Android device must be on the same Wi-Fi network.
  See [Connecting](#connecting).

## Installing

Download the newest `OPRivView-<version>.apk` from
[Geomglot/opview releases](https://github.com/Geomglot/opview/releases). Releases are marked
"Pre-release"; that is normal.

### On a phone or tablet
1. Open the releases page in the phone's browser and tap the `.apk` file under **Assets**.
2. Open the downloaded file. Android asks you to allow installs from your browser the first time:
   allow it, go back, and tap **Install**.

### On the EV Play
The EV Play Max is an Android computer, so OPRivView installs on it like any Android app. Either:
- open the releases page in the EV Play's web browser and download the `.apk` there, or
- download the `.apk` on a computer, copy it to a USB thumb drive, plug the drive into the EV Play
  and open the file with its file manager.

Then allow installs from that app when Android asks, and tap **Install**. The menu names on the
EV Play may differ slightly from a phone's.

### Updating
OPRivView checks for new releases itself: open **Settings** (press and hold anywhere on the
driving screen) and look under **OPRivView updates**. Tap to download, then confirm Android's
install prompt. Your settings are kept.

You can also install a newer `.apk` over the old one by hand. Every release is signed with the same
key, so it installs as an update with no need to uninstall first.

## Connecting

Put the comma and the Android device on one Wi-Fi network. Common ways:
- **The Rivian's own hotspot,** if it is turned on: join it from both the comma and the EV Play (or
  phone).
- **The comma's hotspot:** on the comma, turn on tethering (Settings, Network, Advanced). Join that network from
  the phone or the EV Play.
- **A phone hotspot:** turn on your phone's hotspot and join it from both the comma and the EV Play.
- **Home Wi-Fi**, for trying things out in the driveway.

Open OPRivView. It finds the comma on the network by itself and shows what it is doing on the
**Connecting** screen, along with the installed version. When the comma starts driving (the car is
on), the camera picture and overlay appear.

If it cannot find the comma, open **Settings**, tap **Change** next to **Comma device**, and type the
comma's IP address (shown on the comma under Settings, Network, Advanced). The app remembers it.

The connection repairs itself: if the picture or data stalls, OPRivView rebuilds the stream on its
own, and it reconnects after the network drops or you switch apps.

## Using it

| To do this | Do this |
|---|---|
| Open settings | Press and hold anywhere on the driving screen |
| Change layout | Swipe sideways (left for the next layout, right for the previous) |
| Change the bottom bar | Tap the bottom center of the screen |
| Fold or unfold a panel (Detailed) | Tap the panel |

A swipe that starts right at the edge of the screen is left to Android (for its Back gesture). Start
a little way in.

After a swipe or a tap on the bottom bar, the new choice's name shows briefly in the middle of the
screen.

## The three layouts

All three show the road camera, the path and lane lines, alerts, and a colored border for the
driving state. They differ in how much they add.

### Classic
Close to the comma's own screen: set speed and current speed at the top, alerts at the bottom, the
speed limit sign, road name, steering wheel icon, turn signal arrows, a clock, and MADS border colors.

### Enhanced
Modeled on the comma four's screen, made for a wide display: the picture fills the screen, with
set speed, speed and speed limit along the top, the lead car boxed with its distance, a glow at the
side when the car reports something in your blind spot, the driver monitoring icon, and a model
confidence ball.

### Detailed
Enhanced plus side panels of live data:
- **Steering:** mode, target and actual angle, rate, torque command, driver torque, lateral
  acceleration with a 10 second chart, and the lane centering readout when it is on.
- **Driver:** face, attention and monitoring policy.
- **Longitudinal:** cruise control state, driving personality, commanded and actual acceleration,
  throttle / brake, with a 10 second chart.
- **Lead:** distance, gap, closing speed, lead speed, time to impact, and a second lead car (teal).
- A clock and the comma's health at the top right: CPU, memory, disk, power and calibration.
- A strip along the bottom with the car's and the driving model's state.

Tap any panel to fold it down to its title; tap again to open it. The app remembers which are folded.

## The bottom bar

The space at the bottom center can show one of four things, chosen separately for each layout:

| Choice | Shows |
|---|---|
| **Torque** | How hard openpilot is steering, as an arc that fills left or right |
| **Lane centering** | What lane centering is doing (below) |
| **Auto** | Lane centering while it is turned on in the comma's settings, otherwise Torque |
| **Off** | Nothing |

Change it in **Settings** under **Bottom bar**, or tap the bottom center of the screen to step through
the choices. Classic starts with Off, Enhanced and Detailed with Torque.

### Lane centering
Lane centering is a feature of Geomglot's sunnypilot build that nudges the car back toward the
middle of the lane. It must be turned on in the comma's settings for anything to show here. It only
shows while openpilot is steering.

- **The bar** fills from the center toward the side the car is being pushed.
- **The figures** show how hard it is pushing (in m/s2, meters per second squared, with an arrow for the direction) and how far
  the car is from the center of the lane (in cm, or inches when the comma is set to imperial units).
  When it is not correcting, a word shows instead: "centered", "clear of line" in One-Line Mode,
  or "no lines".
- **Colors:**

| Color | Meaning |
|---|---|
| Mint | Centering between two lane lines |
| Light blue | One-Line Mode: only one lane line is visible, and "one line" shows instead of the distance |
| Amber | A hard push |
| Red | It wanted to push harder than it is allowed to |
| Gray | Paused: no lane lines to center on ("no lines") |
| Dim white | Holding: nothing to correct |

Where it appears:
- **Classic:** a panel at the bottom of the screen, with the figures over a straight bar. While an
  alert shows, it moves up above the alert.
- **Enhanced:** an arc in place of the torque bar, with the figures just above it.
- **Detailed:** the same arc, plus **Centering** and **Push** rows in the Steering panel.

## Settings

Press and hold anywhere on the driving screen.

| Setting | What it does |
|---|---|
| **Layout** | Classic, Enhanced or Detailed. Same as swiping |
| **Bottom bar** | For the current layout: Torque, Lane centering, Auto or Off |
| **Speed limit** | Auto (shown once the comma knows the limit), Always, or Off. All layouts |
| **Brightness** | Auto follows the device's own setting; a level set here applies while OPRivView is open |
| **Comma device** | The comma's address, found automatically or entered by hand with **Change** |
| **Road name** | Show or hide the road name, whatever the comma's own setting |
| **Picture-in-picture** | On: when you leave OPRivView, a small floating view stays on screen (where the device supports it) |
| **OPRivView updates** | Checks for, downloads and installs new releases |

The installed version is shown at the bottom of the settings.

## Picture-in-picture
With **Picture-in-picture** on, going to the Home screen or opening another app shrinks OPRivView to
a small floating window with the essentials. Tap it to return to full screen. Not every head unit
supports this; where it doesn't, the switch has no effect.

## Troubleshooting

| Problem | Try |
|---|---|
| Stuck on "searching for comma device" | Check both are on the same Wi-Fi network; enter the comma's IP address under **Comma device** |
| Connected but no picture | The picture only appears while the comma is driving (car on). Wait a few seconds after starting the car |
| Picture freezes | It should recover on its own within a few seconds; if not, leave the app and come back |
| No lane centering readout | Turn lane centering on in the comma's settings; it shows only while openpilot is steering. The comma needs Geomglot's build |
| Update won't install | Uninstall only if the old app came from somewhere other than Geomglot's releases (a different signing key) |
| Swipe doesn't change the layout | Start the swipe a little way in from the edge |

## Credits

OPRivView builds on:
- [comma.ai openpilot](https://github.com/commaai/openpilot), whose driving screen it reproduces.
- [eFiniLan/opview](https://github.com/eFiniLan/opview), the original Flutter app.
- [Gerrylum/opview](https://github.com/gerrylum/opview): the Enhanced and Detailed layouts, the settings
  menu, swiping between layouts, brightness control, picture-in-picture, in-app updates, signed
  release builds, and the OPRivView name and icon.
- Geomglot: sunnypilot support, MADS colors, lane centering and the bottom bar, and the Rivian
  releases.
