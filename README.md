# Weylus Pencil

A native iPad client for [Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition)
focused on Apple Pencil input. It speaks Weylus' existing WebSocket protocol, so nothing needs to
change on the computer.

## Features (v0.1, input only — no screen mirroring yet)

- Full-rate (240 Hz) Pencil input via coalesced touches, with pressure, tilt and barrel roll
- Hover (M2+ iPad Pro)
- Pressure curve (soft ↔ firm), "full pressure at", and light-touch boost, with a live preview
- Stroke and pressure smoothing, Catmull-Rom curve interpolation
- Apple Pencil double-tap and squeeze mapped to keyboard shortcuts (tap or hold)
- Aspect-correct mapping so circles stay round
- Fingers ignored (palm-friendly); three-finger tap opens the menu

## Building

There's no Mac needed: GitHub Actions builds an unsigned IPA on every push
(Actions tab → latest run → `WeylusPencil-ipa` artifact). Install it with LiveContainer,
SideStore, AltStore or similar.

Locally on a Mac: `brew install xcodegen && xcodegen generate && open WeylusPencil.xcodeproj`.

## Using it

1. Start Weylus on the computer (it serves on port 1701 by default).
2. Open Weylus Pencil, enter the computer's IP, tap Connect, pick the screen.
3. Tap Draw.
