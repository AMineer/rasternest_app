# Architecture

RasterNest is one Swift package. Each layer only depends on the ones above it, so the portable parts stay portable.

| Target | Depends on | Platforms | Purpose |
|---|---|---|---|
| `RasterNestCore` | Foundation | macOS, Linux, Windows | Annotation model, geometry and hit testing, the `.rasternest` file format |
| `RasterNestCapture` | Core | macOS, Linux | Headless capture (`ScreenCapturer`), clipboard, OCR |
| `RasterNestRender` | Core, AppKit | macOS | Draws annotations; flattening, PNG/JPEG encode/decode |
| `rnest` | Core, Capture, Render (macOS) | macOS, Linux | ArgumentParser CLI |
| `RasterNestApp` | all | macOS | Menu-bar app: hotkeys, overlay, editor |

`Package.swift` only declares `RasterNestApp` on macOS. `RasterNestRender` sources are wrapped in `#if canImport(AppKit)`, so on Linux the target compiles empty.

## Coordinates

All annotation geometry is in **image pixels, origin top-left, y down**. Retina captures are stored at full resolution, with `pixelScale` (2.0) recorded alongside. Exported PNGs carry 144 dpi, so they paste at the right size.

## Capture flow (macOS app)

1. A global hotkey fires through Carbon `RegisterEventHotKey`, which needs no Accessibility permission.
2. `CaptureCoordinator` checks Screen Recording permission, then snapshots **every display** with ScreenCaptureKit.
3. `SelectionOverlayController` shows one borderless, non-activating panel per display with the frozen image. On-screen windows (from `CGWindowListCopyWindowInfo`, front to back) are hit-tested for hover.
4. On release, an area is cropped from the frozen image. A window is re-captured with `SCContentFilter(desktopIndependentWindow:)`, so covered parts come out clean.
5. The result is auto-saved and copied, then opened in an `EditorWindowController`.

## Editor

- `EditorModel` (ObservableObject) owns the image, annotations, tool, per-tool styles and an `UndoManager`. Undo works with whole-state snapshots (image + annotation array), which keeps crop undoable.
- `CanvasView` is an `NSView` inside a magnifying `NSScrollView`. It turns mouse/keyboard input into model edits and draws with `AnnotationRenderer`.
- The toolbar and inspector are SwiftUI (`EditorView`).

## Adding a platform

- **Linux GUI / Windows:** reuse `RasterNestCore` (and the `.rasternest` format) as-is. Write a native shell (GTK/Qt on Linux, WinUI/Win32 on Windows), plus a renderer that matches `AnnotationRenderer`'s output.
- **Windows capture:** add `WindowsScreenCapturer` (Windows.Graphics.Capture or BitBlt) behind `#if os(Windows)`, and wire it into `Capturers.make`.
- **Linux `rnest export`:** needs a software rasterizer (e.g. Cairo through a system-library target). Until then it reports "unsupported".
