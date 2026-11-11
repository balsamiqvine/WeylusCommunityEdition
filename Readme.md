# Weylus Pencil

**Use an iPad and Apple Pencil as a drawing tablet and second screen for a Linux computer**, in the
spirit of Astropad. This repository is a fork of
[Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition) with a native
iPad app added in [`ios/`](ios/) and a number of changes to the Weylus server.

> [!WARNING]
> **This fork was made almost entirely by an AI.**
>
> I'm an artist, not a programmer. Nearly all of the code here that isn't from upstream Weylus
> (the iPad app and the changes to the Weylus server) was written by **Claude**, an AI model made
> by Anthropic, over a series of chat sessions in which I described what I wanted, tested the
> results on my own devices and reported back. Commits it wrote are marked
> `Co-Authored-By: Claude`.
>
> What that means for you:
> - **No experienced developer has reviewed this code.** It works on my setup, but it may have
>   bugs, security issues or design problems that someone who knows the field would catch.
> - **It has been tested on exactly one setup** (listed under [Status](#status)). Other GPUs,
>   distributions, desktops and iPads may not work.
> - The iPad app is **not on the App Store** and isn't signed; you install it yourself (see below).
>
> If that's not something you're comfortable with, that's completely fair. The original
> [Weylus](https://github.com/H-M-H/Weylus) and
> [Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition) are
> written by people, and work with any tablet through its web browser.

## What it does

**Weylus** (the part that runs on your computer) shares your screen with the tablet and turns the
tablet's input into a real pen, touchscreen and keyboard on the computer. Upstream Weylus does this
through the tablet's web browser. This fork adds:

**A native iPad app (Weylus Pencil)**
- Apple Pencil input at the full 240 Hz, with pressure, tilt, hover and barrel roll
- Adjustable pressure curve, light-touch boost and stroke/pressure smoothing
- Apple Pencil Pro squeeze and double-tap mapped to keyboard shortcuts
- Hardware video decoding, with a choice of upscaling (MetalFX, Lanczos, bicubic, pixel-perfect)
  and a fix for red/blue colour fringes around sharp edges
- Touch input: finger-tap shortcuts, or a real touchscreen with palm rejection
- An on-screen shortcut bar with buttons you can edit (tap or hold, e.g. hold ctrl while drawing)
- **Mirror** an existing screen, or **Extend** the desktop with the iPad as a second screen
- **Wi-Fi or a USB cable** (wired mode needs no network at all)

**Changes to the Weylus server (Linux, GNOME on Wayland)**
- Pen fixes: correct tilt, and light strokes no longer get lost
- Screen capture that keeps frames on the GPU (much lower CPU use), hardware encoding fixes for
  newer FFmpeg, correct colour information, and only encoding when the screen actually changed
- Virtual displays: the iPad becomes an extra monitor, with pen and touch mapped to it

The upstream web client still works too, and got a pressure curve and smoothing as well.

## Status

Experimental. Tested on one setup:

| | |
|---|---|
| Computer | 2015 laptop, Intel Core i5-5200U with Intel HD 5500 graphics |
| OS | Ubuntu 26.04, GNOME 50 on Wayland |
| Tablet | 13-inch iPad Pro (M4) with Apple Pencil Pro |
| Apps | Krita, Umoupen, Firefox |

Windows and macOS: Weylus itself still builds there, but the new server features (virtual
displays, GPU capture, the USB bridge) are Linux-only and none of it has been tested on those
systems.

## Setting it up

### 1. Weylus on the computer (Linux)

Build it from this repository; see the
[original build instructions](docs/weylus-community-edition.md#building). Then:

- **Pen and touch need uinput access.** Follow the
  [uinput instructions](docs/weylus-community-edition.md#linux), then log out and back in.
- **GNOME on Wayland:** start Weylus with `--wayland-support`, otherwise the screen will be black.
- **Hardware encoding:** add `--try-vaapi`. On older Intel GPUs (around 2014–2016, e.g. HD 5500)
  only the legacy driver can encode: install `i965-va-driver` and `i965-va-driver-shaders` and set
  `LIBVA_DRIVER_NAME=i965`.
- **Ubuntu 26.04 / GNOME 50:** Xwayland 24.1.10 has a bug where pens don't click or draw in X11
  apps such as Krita 5 ([Launchpad #2150325](https://bugs.launchpad.net/ubuntu/+source/xwayland/+bug/2150325)).
  It's fixed in Xwayland 24.1.11 and later.

For example:

```sh
LIBVA_DRIVER_NAME=i965 ./target/release/weylus --wayland-support --try-vaapi
```

Useful environment variables: `WEYLUS_STATS=1` prints frame rate and encoding statistics,
`WEYLUS_NO_DMABUF=1` turns GPU capture off if it causes problems.

### 2. The iPad app

Download `WeylusPencil.ipa` from the [releases](../../releases) (tags starting with `pencil-`) and
install it with [LiveContainer](https://github.com/LiveContainer/LiveContainer),
[SideStore](https://sidestore.io) or [AltStore](https://altstore.io). It isn't signed, so it can't
be installed any other way. You can also build it yourself without a Mac: GitHub Actions builds an
IPA on every change to `ios/` (see [ios/README.md](ios/README.md)).

### 3. Wired mode (optional)

Install `usbmuxd`, plug the iPad in, tap **Trust** on the iPad, and run the bridge next to Weylus:

```sh
python3 ios/tools/weylus-usb-bridge.py
```

Then choose **USB cable** in the app's menu. The bridge waits for the iPad and reconnects by itself.

## Using it

Open the app, enter the computer's IP address (or choose USB), tap **Connect**, and choose a mode:

- **Mirror** shows a screen that already exists. Pick the "Pipewire" entry on GNOME/Wayland.
- **Extend** adds the iPad as a second screen to the right of your display:
  - **Half resolution, pixel-doubled**: normal-sized interface and smooth, but apps draw at half
    the iPad's resolution, so strokes look coarser.
  - **Native**: every iPad pixel, best for drawing, but the interface is small and the frame rate
    depends on how fast the computer can encode video (about 20 fps on an HD 5500).

The menu opens from the **Menu** button in the shortcut bar or with a four-finger tap.

## Known limitations

- The app has to stay open in the foreground; iOS suspends it otherwise (it reconnects when you
  come back).
- Video carries colour at half resolution (standard for H.264), so thin coloured lines can look
  slightly soft. The app reduces the visible fringing but can't remove it completely.
- Don't change the scale of the virtual (Extend) display in GNOME's settings: GNOME 50 then
  delivers only a few frames per second for it.
- Native-resolution Extend mode is limited by the computer's video encoder on older hardware.

## Credits and license

- [Weylus](https://github.com/H-M-H/Weylus) by H-M-H and contributors
- [Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition) by
  electronstudio and contributors
- The iPad app and the server changes in this fork: written by Claude (Anthropic), directed and
  tested by [@balsamiqvine](https://github.com/balsamiqvine)

Licensed like Weylus: GNU Affero General Public License v3.0 or later, see [LICENSE](LICENSE).

The original Weylus Community Edition README, with full documentation of Weylus itself, is in
[docs/weylus-community-edition.md](docs/weylus-community-edition.md).
