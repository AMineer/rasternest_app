import AppKit
import RasterNestCapture
import RasterNestCore
import RasterNestRender

/// Orchestrates a capture: permission → freeze screens → overlay → crop → deliver.
@MainActor
final class CaptureCoordinator {
    enum Mode { case image, text }

    private var overlay: SelectionOverlayController?
    private var scrolling: ScrollingCaptureSession?
    private var recording: RecordingSession?

    /// Screen recording: pick an area, window or screen, 3-2-1, record. Triggering it again stops.
    func startRecording(fromMenu: Bool = false) {
        if let recording {
            recording.stop()
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            guard await ensurePermission() else { busy = false; return }
            if fromMenu { try? await Task.sleep(nanoseconds: 200_000_000) }
            do {
                var snaps: [DisplaySnapshot] = []
                for screen in NSScreen.screens {
                    if let snap = try await snapshot(screen) { snaps.append(snap) }
                }
                guard !snaps.isEmpty else { throw CaptureError.noDisplays }
                let controller = SelectionOverlayController()
                overlay = controller
                controller.begin(snapshots: snaps, windows: MacScreenCapturer.onScreenWindows(),
                                 hint: "Drag an area to record, click a window, or press Space for the whole screen  ·  Esc to cancel") { [weak self] result in
                    guard let self else { return }
                    self.overlay = nil
                    switch result {
                    case .region(let snap, let rect): self.beginRecording(snap, rect)
                    case .window(_, let snap, let rect): self.beginRecording(snap, rect)
                    case .display(let snap): self.beginRecording(snap, CGRect(origin: .zero, size: snap.screen.frame.size))
                    case .cancelled: self.busy = false
                    }
                }
            } catch {
                busy = false
                present(error)
            }
        }
    }

    /// Records an exact area (global points, top-left origin) without the selection overlay,
    /// optionally stopping after `seconds`. Used by `rasternest://record?rect=x,y,w,h&seconds=N`.
    func startRecording(globalRect: CGRect, seconds: Double?) {
        if let recording { recording.stop(); return }
        guard !busy else { return }
        busy = true
        Task {
            guard await ensurePermission() else { busy = false; return }
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                let bounds = CGDisplayBounds(id)
                guard bounds.contains(globalRect.origin) else { continue }
                let local = globalRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    .intersection(CGRect(origin: .zero, size: bounds.size))
                beginRecording(screen: screen, displayID: id, scale: CGFloat(MacScreenCapturer.scale(of: id)),
                               rect: local, autoStopAfter: seconds)
                return
            }
            busy = false
            HUD.show("That area isn't on a display", symbol: "exclamationmark.circle")
        }
    }

    private func beginRecording(_ snap: DisplaySnapshot, _ rect: CGRect) {
        beginRecording(screen: snap.screen, displayID: snap.displayID, scale: snap.scale, rect: rect, autoStopAfter: nil)
    }

    private func beginRecording(screen: NSScreen, displayID: CGDirectDisplayID, scale: CGFloat, rect: CGRect,
                                autoStopAfter seconds: Double?) {
        guard rect.width >= 32, rect.height >= 32 else {
            busy = false
            HUD.show("Pick a larger area to record", symbol: "exclamationmark.circle")
            return
        }
        let s = AppSettings.shared
        let options = RecordingSession.Options(systemAudio: s.recordSystemAudio, microphone: s.recordMicrophone,
                                               showClicks: s.showClicks)
        let session = RecordingSession(screen: screen, displayID: displayID, region: rect,
                                       scale: scale, options: options)
        session.onFinish = { [weak self] url in
            guard let self else { return }
            self.recording = nil
            self.busy = false
            guard let url else { return }
            do {
                let item = try CaptureLibrary.shared.addRecording(url)
                if s.copyToClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([item.videoURL! as NSURL])
                }
                EditorWindowController.show(item)
            } catch {
                self.present(error)
            }
        }
        recording = session
        HUD.countdown(seconds: 3) {
            Task {
                do {
                    try await session.start()
                    if let seconds, seconds > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        session.stop()
                    }
                } catch {
                    self.recording = nil
                    self.busy = false
                    self.present(error)
                }
            }
        }
    }
    private var busy = false

    /// Scrolling capture: pick the area that scrolls, then scroll; Done stitches it into one image.
    /// Triggering it again while recording finishes the capture.
    func startScrolling(fromMenu: Bool = false) {
        if let scrolling {
            scrolling.finish()
            return
        }
        guard !busy else { return }
        busy = true
        Task {
            guard await ensurePermission() else { busy = false; return }
            if fromMenu { try? await Task.sleep(nanoseconds: 200_000_000) }
            do {
                var snaps: [DisplaySnapshot] = []
                for screen in NSScreen.screens {
                    if let snap = try await snapshot(screen) { snaps.append(snap) }
                }
                guard !snaps.isEmpty else { throw CaptureError.noDisplays }
                let controller = SelectionOverlayController()
                overlay = controller
                controller.begin(snapshots: snaps, windows: MacScreenCapturer.onScreenWindows(),
                                 hint: "Drag over the part that scrolls, or click a window  ·  Esc to cancel") { [weak self] result in
                    guard let self else { return }
                    self.overlay = nil
                    switch result {
                    case .region(let snap, let rect): self.beginScrolling(snap, rect)
                    case .window(_, let snap, let rect): self.beginScrolling(snap, rect)
                    case .display(let snap): self.beginScrolling(snap, CGRect(origin: .zero, size: snap.screen.frame.size))
                    case .cancelled: self.busy = false
                    }
                }
            } catch {
                busy = false
                present(error)
            }
        }
    }

    /// Scrolling capture of an exact area (global points, origin top-left of the main display),
    /// skipping the selection overlay. Used by `rasternest://scrolling?rect=x,y,w,h`.
    func startScrolling(globalRect: CGRect) {
        if let scrolling { scrolling.finish(); return }
        guard !busy else { return }
        busy = true
        Task {
            guard await ensurePermission() else { busy = false; return }
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                let bounds = CGDisplayBounds(id)
                guard bounds.contains(globalRect.origin) else { continue }
                let local = globalRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    .intersection(CGRect(origin: .zero, size: bounds.size))
                beginScrolling(screen: screen, displayID: id, scale: CGFloat(MacScreenCapturer.scale(of: id)), rect: local)
                return
            }
            busy = false
            HUD.show("That area isn't on a display", symbol: "exclamationmark.circle")
        }
    }

    private func beginScrolling(_ snap: DisplaySnapshot, _ rect: CGRect) {
        beginScrolling(screen: snap.screen, displayID: snap.displayID, scale: snap.scale, rect: rect)
    }

    private func beginScrolling(screen: NSScreen, displayID: CGDirectDisplayID, scale: CGFloat, rect: CGRect) {
        guard rect.width >= 40, rect.height >= 60 else {
            busy = false
            HUD.show("Pick a larger area to scroll", symbol: "exclamationmark.circle")
            return
        }
        let session = ScrollingCaptureSession(screen: screen, displayID: displayID, region: rect, scale: scale)
        session.onFinish = { [weak self] image, scale in
            guard let self else { return }
            self.scrolling = nil
            Task {
                defer { self.busy = false }
                if let image { await self.deliver(image, scale: scale, mode: .image) }
            }
        }
        scrolling = session
        Task {
            do {
                try await session.start()
            } catch {
                session.cancel()
                present(error)
            }
        }
    }

    /// All-in-one capture (area, window or display). `fromMenu` waits for the menu to fade out.
    func startInteractive(mode: Mode = .image, delay: Int = 0, fromMenu: Bool = false) {
        guard !busy else { return }
        busy = true
        Task {
            guard await ensurePermission() else { busy = false; return }
            let go: () -> Void = { [weak self] in self?.runInteractive(mode: mode) }
            if delay > 0 {
                HUD.countdown(seconds: delay, completion: go)
            } else if fromMenu {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: go)
            } else {
                go()
            }
        }
    }

    func captureFullScreen(fromMenu: Bool = false) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await ensurePermission() else { return }
            if fromMenu { try? await Task.sleep(nanoseconds: 200_000_000) }
            do {
                guard let screen = NSScreen.underMouse, let snap = try await snapshot(screen) else {
                    throw CaptureError.noDisplays
                }
                await deliver(snap.image, scale: snap.scale, mode: .image)
            } catch {
                present(error)
            }
        }
    }

    // MARK: Flow

    private func runInteractive(mode: Mode) {
        Task {
            do {
                var snaps: [DisplaySnapshot] = []
                for screen in NSScreen.screens {
                    if let snap = try await snapshot(screen) { snaps.append(snap) }
                }
                guard !snaps.isEmpty else { throw CaptureError.noDisplays }
                let windows = MacScreenCapturer.onScreenWindows()
                let controller = SelectionOverlayController()
                overlay = controller
                let hint = mode == .text
                    ? "Select text to copy  ·  click a window  ·  Esc to cancel"
                    : "Drag to capture an area  ·  click a window  ·  Space for full screen  ·  Esc to cancel"
                controller.begin(snapshots: snaps, windows: windows, hint: hint) { [weak self] result in
                    self?.overlay = nil
                    self?.handle(result, mode: mode)
                }
            } catch {
                busy = false
                present(error)
            }
        }
    }

    private func handle(_ result: SelectionOverlayController.Result, mode: Mode) {
        Task {
            defer { busy = false }
            switch result {
            case .cancelled:
                return
            case .display(let snap):
                await deliver(snap.image, scale: snap.scale, mode: mode)
            case .region(let snap, let rect):
                if let image = crop(snap, rect) { await deliver(image, scale: snap.scale, mode: mode) }
            case .window(let info, let snap, let visibleRect):
                // Prefer a clean grab of the whole window; fall back to the frozen pixels.
                if let (image, scale) = try? await MacScreenCapturer.captureWindow(id: info.id) {
                    await deliver(image, scale: CGFloat(scale), mode: mode)
                } else if let image = crop(snap, visibleRect) {
                    await deliver(image, scale: snap.scale, mode: mode)
                }
            }
        }
    }

    private func snapshot(_ screen: NSScreen) async throws -> DisplaySnapshot? {
        guard let id = screen.displayID else { return nil }
        let (image, _) = try await MacScreenCapturer.snapshot(displayID: id)
        return DisplaySnapshot(screen: screen, displayID: id, image: image,
                               scale: CGFloat(image.width) / screen.frame.width)
    }

    private func crop(_ snap: DisplaySnapshot, _ rect: CGRect) -> CGImage? {
        let s = snap.scale
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        return snap.image.cropping(to: pixels)
    }

    private func deliver(_ image: CGImage, scale: CGFloat, mode: Mode) async {
        switch mode {
        case .text:
            do {
                let text = try await TextRecognition.recognize(cgImage: image)
                if text.isEmpty {
                    HUD.show("No text found", symbol: "text.magnifyingglass")
                } else {
                    try Clipboard.copyText(text)
                    let lines = text.split(separator: "\n").count
                    HUD.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text", symbol: "text.viewfinder")
                }
            } catch {
                present(error)
            }
        case .image:
            let settings = AppSettings.shared
            let item: CaptureLibrary.Item?
            do {
                item = try CaptureLibrary.shared.addCapture(image: image, scale: scale)
            } catch {
                item = nil
                present(error)
            }
            if settings.copyToClipboard { ImageExport.copyToPasteboard(image, scale: scale) }
            if settings.openEditor, let item {
                EditorWindowController.show(item)
            } else if settings.copyToClipboard {
                HUD.show("Copied to clipboard")
            } else {
                HUD.show("Saved", symbol: "tray.and.arrow.down.fill")
            }
        }
    }

    // MARK: Errors & permission

    /// The preflight check can be stale right after a grant (or after a re-sign), so before
    /// nagging, ask ScreenCaptureKit directly whether capture actually works.
    private func ensurePermission() async -> Bool {
        if Permissions.hasScreenCapture { return true }
        if await Permissions.screenCaptureKitWorks() { return true }
        Permissions.presentScreenRecordingAlert()
        return false
    }

    private func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

enum CaptureError: LocalizedError {
    case noDisplays
    var errorDescription: String? { "No displays are available to capture." }
}
