<p align="center">
  <a href="https://rasternest.app">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.png">
      <img alt="RasterNest: Capture. Refine. Share." src="docs/assets/banner-light.png" width="640">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://rasternest.app"><img alt="Website" src="https://img.shields.io/badge/rasternest.app-7C3AED?style=flat-square"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-0B1020?style=flat-square&logo=apple">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="https://github.com/sponsors/A2M4-Systems-LLC"><img alt="Sponsor" src="https://img.shields.io/badge/sponsor-%E2%99%A5-DB2777?style=flat-square&logo=githubsponsors&logoColor=white"></a>
  <a href="https://buymeacoffee.com/rasternest"><img alt="Buy me a coffee" src="https://img.shields.io/badge/buy%20me%20a%20coffee-FFDD00?style=flat-square&logo=buymeacoffee&logoColor=black"></a>
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-0EA5E9?style=flat-square"></a>
  <a href="https://github.com/AMineer/rasternest_app/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/AMineer/rasternest_app/ci.yml?branch=main&style=flat-square&label=CI"></a>
</p>

# RasterNest

**Open-source screen capture and markup.** Grab an area, window or screen with one shortcut, mark it up with arrows, callouts, step numbers and redaction, then copy, drag or export it. Native on macOS, with a scriptable `rnest` CLI for macOS and Linux.

> Status: early (v0.1). macOS app + CLI work today; Linux is CLI-only; Windows is on the roadmap.

## Features

**Capture (⌃⇧C by default)**
- All-in-one: hover to highlight a window and click to capture it; drag to capture an area; Space captures the whole display
- Frozen screen while you select, a pixel magnifier, and live size readout
- **Screen recording** (⌃⇧R): record an area, window or screen to MP4 (H.264, 30 fps) with optional system audio, microphone and on-screen keystrokes; trim it and export a GIF
- **Adjust before capturing**: after dragging an area, resize it with handles or arrow keys and press Return
- **Scrolling capture** (⌃⇧S): pick the area that scrolls, scroll, and get one tall image. Sticky headers appear once
- Full screen (⌃⇧F), delayed capture (3/5/10 s), and **Grab Text** OCR (⌃⇧T) straight to the clipboard
- Each capture is copied to the clipboard, saved to `~/Pictures/RasterNest`, and opened in the editor (each step can be turned off)

**One editor for all your captures**
- A strip of recent captures sits beside the editor. Click any one to go back and change it
- Edits save automatically: every capture is an editable `.rasternest` file with an up-to-date `.png` beside it, ready for docs
- Drag a thumbnail straight into Slack, Notion or a doc

**Markup**
- Arrow, line, rectangle, ellipse, highlighter, text and callouts, numbered steps, pixelate (redact), spotlight, **magnify lens**, pen, crop
- **Frames**: padding, gradient or solid background, rounded corners, drop shadow and border, with presets and a default for new captures
- Single-key tool shortcuts (`A` arrow, `R` rect, `T` text, `N` step, `B` pixelate…), Shift to snap angles/squares
- Per-tool styles (color, width, size, fill, shadow) that stick between captures
- Full undo/redo, nudge with arrow keys, duplicate, and reorder
- Copy (⌘C), drag the image out into any app, export PNG/JPEG/PDF (⌘E), or save an editable `.rasternest` file (⌘S)
- **Export PDF**: combine captures into one guide, one per page (fit, Letter or A4, optional captions)

**CLI: `rnest`**
```sh
rnest capture                       # pick an area or window
rnest capture --region              # drag out an area
rnest capture --window              # click a window
rnest capture --fullscreen -c       # whole display → clipboard
rnest capture --rect 0,0,800,600    # exact rectangle
rnest capture --region --text       # OCR an area, print the text
rnest ocr screenshot.png
rnest export demo.mp4 --format gif --width 640   # recording → GIF
rnest export step1.rasternest step2.rasternest --format pdf --page-size letter --captions -o guide.pdf
rnest export notes.rasternest --format png
rnest displays | rnest windows | rnest backends
```

## Install

**Homebrew (macOS)**: app plus `rnest`:
```sh
brew trust amineer/tap      # once: Homebrew 7 asks you to trust third-party taps
brew install --cask amineer/tap/rasternest
```

**Homebrew (Linux or CLI only)**:
```sh
brew trust amineer/tap
brew install amineer/tap/rnest
```

**Direct download**: grab `RasterNest-x.y.z.dmg` from [Releases](../../releases) and drag it to Applications. From 0.4 on, RasterNest updates itself (Check for Updates… in the menu bar menu).

On first capture, macOS asks for **Screen Recording** permission (System Settings › Privacy & Security › Screen & System Audio Recording). When you use `rnest` from a terminal, the permission belongs to that terminal app.

**Linux**: `rnest` uses whichever screenshot tool you have:

| Session | Tools (first found wins) | Extras |
|---|---|---|
| Wayland | `grim` + `slurp`, `gnome-screenshot`, `spectacle` | `wl-clipboard` |
| X11 | `maim` + `slop`, `scrot`, `gnome-screenshot`, `spectacle`, `imagemagick` | `xclip`, `wmctrl` |

OCR on Linux uses `tesseract`. Run `rnest backends` to see what was detected, or force one with `--backend`.

## Build from source

Requires Xcode 16+ (Swift 6) on macOS 14+, or Swift 6 on Linux.

```sh
make test        # unit tests
make run         # build, sign and launch build/RasterNest.app
make cli         # release rnest tarball for this OS
make dmg         # universal app + DMG
make linux-check # build/test the Linux CLI in Docker
```

`scripts/build-app.sh` signs with your first *Developer ID Application* or *Apple Development* identity, falling back to ad-hoc. A stable identity means macOS remembers the Screen Recording permission across rebuilds.

## Automation

The app handles `rasternest://` URLs, so launchers (Raycast, Alfred, Shortcuts) can trigger it:

```sh
open "rasternest://capture"            # all-in-one capture
open "rasternest://capture?delay=5"
open "rasternest://fullscreen"
open "rasternest://text"               # grab text
open "rasternest://record"             # record the screen (again to stop)
open "rasternest://record?rect=0,120,900,600&seconds=10"   # record an exact area for 10 s
open "rasternest://scrolling"          # scrolling capture (again to finish)
open "rasternest://scrolling?rect=0,120,900,700"   # scroll-capture an exact area
```

## Docs

- [Architecture](docs/ARCHITECTURE.md): how the package is layered and how to add a platform
- [Distribution](docs/DISTRIBUTION.md): signing, notarization, DMG hosting, Homebrew tap
- [Roadmap](docs/ROADMAP.md): feature parity checklist
- [Brand](docs/BRAND.md): logo, colors and type
- [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE)
