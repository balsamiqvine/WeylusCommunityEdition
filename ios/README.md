# Weylus Pencil

> [!WARNING]
> This app was written almost entirely by Claude, an AI model by Anthropic, directed and tested by
> an artist rather than a programmer. No experienced developer has reviewed it, and it has only been
> tested on one setup. See the [main README](../Readme.md) for details.

A native iPad client for Weylus, focused on Apple Pencil input. It speaks Weylus' WebSocket
protocol; the quality settings, GPU capture and Extend mode need the Weylus server from this
repository.

## Features

- Apple Pencil at 240 Hz (coalesced touches) with pressure, tilt, hover and barrel roll
- Pressure curve, full-pressure point, light-touch boost, stroke and pressure smoothing
- Apple Pencil Pro double-tap and squeeze mapped to keyboard shortcuts (tap or hold)
- Hardware H.264 decoding (VideoToolbox) and a Metal renderer: luma-guided chroma upsampling
  against colour fringes, MetalFX / Lanczos-3 / bicubic / bilinear / integer upscaling, and
  FSR 1.0 RCAS sharpening
- Mirror an existing screen, or Extend the desktop with a virtual display (half resolution
  pixel-doubled, or native)
- Touch: finger-tap shortcuts, or a touchscreen with palm rejection
- Editable shortcut bar with tap and hold buttons
- Wi-Fi, or wired over USB through `tools/weylus-usb-bridge.py`
- iPad-drawn cursor at the Pencil, so cursor movement costs no video

## Building

No Mac needed: GitHub Actions builds an unsigned IPA on every push that touches `ios/`
(Actions tab → "Weylus Pencil (iPad)" → latest run → `WeylusPencil-ipa`). Releases are published
with tags starting with `pencil-`. Install with LiveContainer, SideStore, AltStore or similar.

On a Mac: `brew install xcodegen && xcodegen generate && open WeylusPencil.xcodeproj`.

## Wired mode

iOS only lets the computer open connections to an app over USB, so in USB mode the app listens on
its port and `tools/weylus-usb-bridge.py` (Python 3, no dependencies, needs `usbmuxd`) connects into
it through the cable and relays to Weylus on the computer.
