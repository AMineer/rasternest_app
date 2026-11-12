# Roadmap

Feature checklist against a typical commercial capture tool. ✅ done · 🟡 partial · ⬜ planned

## Capture
- ✅ All-in-one area / window / full-screen selection with frozen screen
- ✅ Window capture of covered windows (ScreenCaptureKit)
- ✅ Pixel magnifier and size readout
- ✅ Delayed capture
- ✅ Grab text (OCR → clipboard)
- ✅ Global, customizable hotkeys
- ✅ CLI capture on macOS and Linux
- ⬜ Adjust the selection after dragging (handles, arrow-key nudge) before confirming
- ✅ Scrolling capture (manual scroll, sticky header/footer detection)
- ⬜ Auto-scrolling capture and `rnest capture --scrolling`
- ✅ Screen recording to MP4 with system audio + microphone (macOS 15), trim, GIF export
- ⬜ Pause/resume, webcam overlay, and keystroke display while recording
- ⬜ Capture the cursor (optional)
- ⬜ Capture presets / profiles
- ⬜ Color picker (hex from the magnifier)

## Markup
- ✅ Arrow, line, rectangle, ellipse, highlighter, text, callout, step numbers, pixelate, spotlight, pen, crop
- ✅ Per-tool styles, palette + custom colors, shadows, fills
- ✅ Undo/redo, nudge, duplicate, z-order
- ⬜ Arrow styles (curved, double-headed, tapered)
- ⬜ Blur (gaussian) in addition to pixelate
- ⬜ Magnify/loupe annotation
- ⬜ Stamps and emoji
- ⬜ Image resize, canvas padding, borders, torn edges
- ⬜ Smart move / text replacement in screenshots
- ⬜ Multi-select

## Library & sharing
- ✅ Auto-save to folder, recent captures menu
- ✅ Copy, drag-out, export PNG/JPEG, editable `.rasternest` files
- ✅ One editor window with a strip of recent captures; autosave with rendered PNGs
- ⬜ Library browser with tags and search
- ⬜ Share targets (upload to S3, Imgur, Slack, custom webhook)
- ⬜ PDF export

## Platform
- ✅ macOS 14+ native app
- ✅ Homebrew cask + formula, signed/notarized DMG pipeline
- 🟡 Linux: CLI capture/OCR/clipboard (no GUI editor, no `export` yet)
- ⬜ Sparkle auto-updates
- ⬜ Linux GUI editor (GTK or Qt) on `RasterNestCore`
- ⬜ Windows app (WinUI) + `rnest` for Windows
