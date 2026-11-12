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

    /// After dragging out an area it stays adjustable until Return / Capture.
    private var adjusting: CGRect?
    private enum AdjustDrag { case none, move(origin: CGPoint, start: CGRect), handle(Int, start: CGRect) }
    private var adjustDrag: AdjustDrag = .none
    private var captureButton: CGRect = .null
    private var cancelButton: CGRect = .null

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
        guard let m = mouse, dragRect == nil, adjusting == nil else { hovered = nil; return }
        hovered = windows.first { $0.1.contains(m) }
    }

    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = location(event)
        mouse = p
        updateHover()
        cursor(at: p).set()
        needsDisplay = true
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard let r = adjusting else { return .crosshair }
        if captureButton.contains(p) || cancelButton.contains(p) { return .pointingHand }
        if let i = handleIndex(at: p, of: r) {
            switch i {
            case 1, 5: return .resizeUpDown
            case 3, 7: return .resizeLeftRight
            default: return .crosshair
            }
        }
        return r.contains(p) ? .openHand : .crosshair
    }

    // MARK: Adjusting

    /// Corner and edge handles: tl, t, tr, r, br, b, bl, l.
    private func handles(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handleIndex(at p: CGPoint, of r: CGRect) -> Int? {
        handles(of: r).firstIndex { abs($0.x - p.x) <= 8 && abs($0.y - p.y) <= 8 }
    }

    private func resized(_ start: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        default: minX = p.x
        }
        return Geometry.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)).intersection(bounds)
    }

    private func clampedMove(_ r: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var moved = r.offsetBy(dx: dx, dy: dy)
        moved.origin.x = min(max(moved.minX, 0), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, 0), bounds.maxY - moved.height)
        return moved
    }

    private func confirmAdjusted() {
        guard let r = adjusting?.integral, r.width >= 3, r.height >= 3 else { return }
        onFinish(.region(snapshot, r))
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
        if let r = adjusting {
            if captureButton.contains(p) { confirmAdjusted(); return }
            if cancelButton.contains(p) { onFinish(.cancelled); return }
            if let i = handleIndex(at: p, of: r) { adjustDrag = .handle(i, start: r); return }
            if r.contains(p) {
                if event.clickCount >= 2 { confirmAdjusted(); return }
                adjustDrag = .move(origin: p, start: r)
                NSCursor.closedHand.set()
                return
            }
            adjusting = nil   // clicking outside starts a new selection
        }
        dragOrigin = p
        mouse = p
        hint = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = location(event)
        switch adjustDrag {
        case .move(let origin, let start):
            adjusting = clampedMove(start, dx: p.x - origin.x, dy: p.y - origin.y)
            mouse = nil
            needsDisplay = true
            return
        case .handle(let i, let start):
            adjusting = resized(start, handle: i, to: p)
            mouse = p
            needsDisplay = true
            return
        case .none:
            break
        }
        guard let origin = dragOrigin else { return }
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
        if case .none = adjustDrag {} else {
            adjustDrag = .none
            mouse = location(event)
            needsDisplay = true
            return
        }
        if let r = dragRect {
            dragRect = nil
            if r.width >= 3 && r.height >= 3 {
                if AppSettings.shared.adjustBeforeCapture {
                    adjusting = r
                    hint = nil
                    needsDisplay = true
                } else {
                    onFinish(.region(snapshot, r))
                }
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
        if let r = adjusting {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let resize = event.modifierFlags.contains(.option)
            var next = r
            switch event.keyCode {
            case 53: onFinish(.cancelled); return
            case 36, 76, 49: confirmAdjusted(); return
            case 123: next = resize ? CGRect(x: r.minX, y: r.minY, width: max(4, r.width - step), height: r.height) : clampedMove(r, dx: -step, dy: 0)
            case 124: next = resize ? CGRect(x: r.minX, y: r.minY, width: r.width + step, height: r.height).intersection(bounds) : clampedMove(r, dx: step, dy: 0)
            case 125: next = resize ? CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + step).intersection(bounds) : clampedMove(r, dx: 0, dy: step)
            case 126: next = resize ? CGRect(x: r.minX, y: r.minY, width: r.width, height: max(4, r.height - step)) : clampedMove(r, dx: 0, dy: -step)
            default: super.keyDown(with: event); return
            }
            adjusting = next
            needsDisplay = true
            return
        }
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
        let focus = adjusting ?? dragRect ?? hovered?.1

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.38))
        if let focus {
            ctx.addRect(bounds)
            ctx.addRect(focus)
            ctx.fillPath(using: .evenOdd)
            if adjusting != nil || dragRect != nil {
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

        if dragRect == nil, adjusting == nil, let m = mouse { drawCrosshair(ctx, at: m) }

        if let r = adjusting {
            drawAdjusting(ctx, r)
        } else if let r = dragRect {
            drawLabel("\(px(r.width)) × \(px(r.height))", at: CGPoint(x: r.maxX - 90, y: r.maxY + 8))
        } else if let (info, r) = hovered {
            let name = info.owner.isEmpty ? "Window" : info.owner
            drawLabel("\(name)  \(px(r.width)) × \(px(r.height))", at: CGPoint(x: r.minX + 8, y: r.minY + 8))
        }

        if let m = mouse {
            if adjusting == nil {
                drawLoupe(ctx, at: m)
            } else if case .handle = adjustDrag {
                drawLoupe(ctx, at: m)
            }
        }
        if let hint { drawHint(hint) }
    }

    private func px(_ v: CGFloat) -> Int { Int((v * snapshot.scale).rounded()) }

    private func drawAdjusting(_ ctx: CGContext, _ r: CGRect) {
        // Handles
        for h in handles(of: r) {
            let box = CGRect(x: h.x - 4.5, y: h.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)
            ctx.setStrokeColor(Brand.violet.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(box)
        }

        // Toolbar: size · Cancel · Capture, under the area (or above / inside when there's no room)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let sizeText = "\(px(r.width)) × \(px(r.height))" as NSString
        let cancelText = "Cancel" as NSString, captureText = "Capture  ↩" as NSString
        let sizeW = sizeText.size(withAttributes: attrs).width
        let cancelW = cancelText.size(withAttributes: attrs).width + 24
        let captureW = captureText.size(withAttributes: attrs).width + 28
        let height: CGFloat = 34, pad: CGFloat = 6
        let width = pad + sizeW + 16 + cancelW + 6 + captureW + pad
        var origin = CGPoint(x: r.maxX - width, y: r.maxY + 10)
        if origin.y + height > bounds.maxY - 6 { origin.y = r.minY - height - 10 }
        if origin.y < 6 { origin.y = r.maxY - height - 10 }
        origin.x = min(max(origin.x, 6), bounds.maxX - width - 6)
        let bar = CGRect(origin: origin, size: CGSize(width: width, height: height))

        NSColor(white: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
        sizeText.draw(at: CGPoint(x: bar.minX + pad + 6, y: bar.midY - 8), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.75)])

        cancelButton = CGRect(x: bar.minX + pad + sizeW + 16, y: bar.minY + 4, width: cancelW, height: height - 8)
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: cancelButton, xRadius: 7, yRadius: 7).fill()
        cancelText.draw(at: CGPoint(x: cancelButton.minX + 12, y: cancelButton.midY - 8.5), withAttributes: attrs)

        captureButton = CGRect(x: cancelButton.maxX + 6, y: bar.minY + 4, width: captureW, height: height - 8)
        Brand.violet.setFill()
        NSBezierPath(roundedRect: captureButton, xRadius: 7, yRadius: 7).fill()
        captureText.draw(at: CGPoint(x: captureButton.minX + 14, y: captureButton.midY - 8.5), withAttributes: attrs)
    }

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
