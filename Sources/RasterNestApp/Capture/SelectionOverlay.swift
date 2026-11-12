import AppKit
import RasterNestCapture
import RasterNestCore
import RasterNestRender

/// A frozen image of one display, taken when a capture starts.
struct DisplaySnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Image pixels per screen point.
    let scale: CGFloat
}

/// Full-screen "all-in-one" selection: hover highlights windows, click captures a window
/// (or the whole display on empty desktop), drag captures an area.
@MainActor
final class SelectionOverlayController {
    enum Result {
        case region(DisplaySnapshot, CGRect)   // rect in display-local points, y down
        case window(MacScreenCapturer.WindowInfo, DisplaySnapshot, CGRect)
        case display(DisplaySnapshot)
        case cancelled
    }

    private var panels: [OverlayPanel] = []
    private var completion: ((Result) -> Void)?

    func begin(snapshots: [DisplaySnapshot], windows: [MacScreenCapturer.WindowInfo], hint: String,
               completion: @escaping (Result) -> Void) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation

        for snap in snapshots {
            let frame = snap.screen.frame
            let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.setFrame(frame, display: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            // Window frames are global, y-down; make them local to this display.
            let displayBounds = CGDisplayBounds(snap.displayID)
            let local = CGRect(origin: .zero, size: frame.size)
            let localWindows: [(MacScreenCapturer.WindowInfo, CGRect)] = windows.compactMap { info in
                let r = info.frame.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY).intersection(local)
                return (r.isNull || r.width < 20 || r.height < 20) ? nil : (info, r)
            }

            let container = NSView(frame: local)
            let background = NSView(frame: local)
            background.wantsLayer = true
            background.layer?.contents = snap.image
            background.layer?.contentsGravity = .resize
            background.autoresizingMask = [.width, .height]

            let isMouseScreen = NSMouseInRect(mouse, frame, false)
            let overlay = OverlayView(frame: local, snapshot: snap, windows: localWindows,
                                      hint: isMouseScreen ? hint : nil) { [weak self] result in
                self?.finish(result)
            }
            overlay.autoresizingMask = [.width, .height]
            if isMouseScreen {
                overlay.mouse = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
                overlay.updateHover()
            }
            container.addSubview(background)
            container.addSubview(overlay)
            panel.contentView = container
            panel.initialFirstResponder = overlay
            panels.append(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        let keyPanel = panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first
        keyPanel?.makeKey()
        if let overlay = keyPanel?.contentView?.subviews.last { keyPanel?.makeFirstResponder(overlay) }
        NSCursor.crosshair.set()
    }

    private func finish(_ result: Result) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    let snapshot: DisplaySnapshot
    let windows: [(MacScreenCapturer.WindowInfo, CGRect)]
    var hint: String?
    let onFinish: (SelectionOverlayController.Result) -> Void

    var mouse: CGPoint?
    private var dragOrigin: CGPoint?
    private var dragRect: CGRect?
    private var hovered: (MacScreenCapturer.WindowInfo, CGRect)?

    init(frame: CGRect, snapshot: DisplaySnapshot, windows: [(MacScreenCapturer.WindowInfo, CGRect)], hint: String?,
         onFinish: @escaping (SelectionOverlayController.Result) -> Void) {
        self.snapshot = snapshot
        self.windows = windows
        self.hint = hint
        self.onFinish = onFinish
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func updateHover() {
        guard let m = mouse, dragRect == nil else { hovered = nil; return }
        hovered = windows.first { $0.1.contains(m) }
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = location(event)
        updateHover()
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = location(event)
        dragOrigin = p
        mouse = p
        hint = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = location(event)
        mouse = p
        let r = Geometry.rect(origin, p)
        if r.width >= 3 || r.height >= 3 {
            dragRect = r
            hovered = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if let r = dragRect {
            dragRect = nil
            if r.width >= 3 && r.height >= 3 {
                onFinish(.region(snapshot, r))
            } else {
                needsDisplay = true
            }
            return
        }
        if let (info, rect) = hovered {
            onFinish(.window(info, snapshot, rect))
        } else {
            onFinish(.display(snapshot))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish(.cancelled) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish(.cancelled)                    // Esc
        case 49, 36, 76: onFinish(.display(snapshot))    // Space / Return: whole display
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onFinish(.cancelled) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let focus = dragRect ?? hovered?.1

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.38))
        if let focus {
            ctx.addRect(bounds)
            ctx.addRect(focus)
            ctx.fillPath(using: .evenOdd)
            if dragRect != nil {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
                ctx.setLineWidth(1)
            } else {
                ctx.setStrokeColor(Brand.highlight.cgColor)
                ctx.setLineWidth(3)
            }
            ctx.stroke(focus.insetBy(dx: -0.5, dy: -0.5))
        } else {
            ctx.fill(bounds)
        }

        if dragRect == nil, let m = mouse { drawCrosshair(ctx, at: m) }

        if let r = dragRect {
            drawLabel("\(px(r.width)) × \(px(r.height))", at: CGPoint(x: r.maxX - 90, y: r.maxY + 8))
        } else if let (info, r) = hovered {
            let name = info.owner.isEmpty ? "Window" : info.owner
            drawLabel("\(name)  \(px(r.width)) × \(px(r.height))", at: CGPoint(x: r.minX + 8, y: r.minY + 8))
        }

        if let m = mouse { drawLoupe(ctx, at: m) }
        if let hint { drawHint(hint) }
    }

    private func px(_ v: CGFloat) -> Int { Int((v * snapshot.scale).rounded()) }

    private func drawCrosshair(_ ctx: CGContext, at m: CGPoint) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        ctx.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.9))
        ctx.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: m.y.rounded() + 0.5))
        ctx.move(to: CGPoint(x: m.x.rounded() + 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: m.x.rounded() + 0.5, y: bounds.maxY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Magnified pixels around the cursor for pixel-precise selection.
    private func drawLoupe(_ ctx: CGContext, at m: CGPoint) {
        let s = snapshot.scale
        let samples: CGFloat = 15
        let cx = (m.x * s).rounded(.down), cy = (m.y * s).rounded(.down)
        let source = CGRect(x: cx - 7, y: cy - 7, width: samples, height: samples)
        guard source.minX >= 0, source.minY >= 0,
              source.maxX <= CGFloat(snapshot.image.width), source.maxY <= CGFloat(snapshot.image.height),
              let sub = snapshot.image.cropping(to: source) else { return }

        let size: CGFloat = 120
        var origin = CGPoint(x: m.x + 22, y: m.y + 22)
        if origin.x + size > bounds.maxX - 4 { origin.x = m.x - 22 - size }
        if origin.y + size + 30 > bounds.maxY - 4 { origin.y = m.y - 22 - size - 30 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))
        let clip = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)

        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.interpolationQuality = .none
        AnnotationRenderer.drawImage(sub, in: box, ctx)
        let cell = size / samples
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: box.minX + 7 * cell, y: box.minY + 7 * cell, width: cell, height: cell))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(clip)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(2)
        ctx.setShadow(offset: .zero, blur: 6, color: CGColor(gray: 0, alpha: 0.6))
        ctx.strokePath()
        ctx.restoreGState()

        drawLabel("\(Int(cx)), \(Int(cy))", at: CGPoint(x: box.minX, y: box.maxY + 6))
    }

    private func drawLabel(_ text: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        var r = CGRect(x: p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        r.origin.x = min(max(r.minX, 4), bounds.maxX - r.width - 4)
        r.origin.y = min(max(r.minY, 4), bounds.maxY - r.height - 4)
        NSColor(white: 0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let r = CGRect(x: bounds.midX - size.width / 2 - 16, y: 60, width: size.width + 32, height: size.height + 16)
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 16, y: r.minY + 8), withAttributes: attrs)
    }
}
