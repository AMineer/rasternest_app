import AppKit
import Combine
import RasterNestCore
import RasterNestRender

/// The drawing surface. Coordinates are image pixels (y down); the enclosing scroll view handles zoom.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    private let renderer: AnnotationRenderer
    private var cancellables = Set<AnyCancellable>()

    private enum DragState {
        case none
        case creating(UUID)
        case moving(UUID, origin: CGPoint, original: Annotation)
        case handle(UUID, index: Int)
        case cropping(origin: CGPoint)
    }

    private var drag: DragState = .none
    private var dragStartSnapshot: EditorModel.Snapshot?

    private var textField: NSTextField?
    private var editingID: UUID?
    private var editingSnapshot: EditorModel.Snapshot?
    private var editingIsNew = false

    init(model: EditorModel) {
        self.model = model
        self.renderer = AnnotationRenderer(unit: model.pixelScale)
        super.init(frame: CGRect(origin: .zero, size: model.imageSize))
        model.objectWillChange
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        model.$image
            .sink { [weak self] image in self?.setFrameSize(CGSize(width: image.width, height: image.height)) }
            .store(in: &cancellables)
        model.$tool
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.01) }
    private var hitTolerance: CGFloat { 6 / magnification }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        renderer.render(base: model.image, annotations: model.annotations, in: ctx, textHiddenFor: editingID)
        if model.tool == .crop {
            drawCropOverlay(ctx)
        } else if let selected = model.selected, selected.id != editingID {
            drawSelection(selected, ctx)
        }
    }

    private func drawSelection(_ a: Annotation, _ ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let m = magnification
        ctx.saveGState()
        ctx.setLineWidth(1 / m)
        if a.kind != .arrow && a.kind != .line {
            ctx.setStrokeColor(accent)
            ctx.setLineDash(phase: 0, lengths: [4 / m, 3 / m])
            ctx.stroke(a.bounds.insetBy(dx: -3 / m, dy: -3 / m))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let size = 9 / m
        for h in a.handles {
            let r = CGRect(x: h.x - size / 2, y: h.y - size / 2, width: size, height: size)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(r)
            ctx.setStrokeColor(accent)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        guard let r = model.cropRect else { return }
        let m = magnification
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.addRect(model.imageBounds)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5 / m)
        ctx.stroke(r)
        // Rule-of-thirds guides
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(1 / m)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Hit testing

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func hit(_ p: CGPoint) -> Annotation? {
        model.annotations.reversed().first { $0.hitTest(p, tolerance: hitTolerance) }
    }

    private func handleIndex(at p: CGPoint, of a: Annotation) -> Int? {
        let reach = 8 / magnification
        return a.handles.firstIndex { Geometry.distance($0, p) <= reach }
    }

    private func startMove(_ a: Annotation, from p: CGPoint) {
        dragStartSnapshot = model.snapshot
        drag = .moving(a.id, origin: p, original: a)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let wasEditing = editingID != nil
        window?.makeFirstResponder(self)   // ends any text editing
        finishEditing()
        let p = point(event)

        if event.clickCount == 2, let h = hit(p), h.kind == .text {
            model.selectedID = h.id
            beginEditing(h.id, isNew: false)
            return
        }

        if model.tool == .crop {
            drag = .cropping(origin: p)
            model.cropRect = nil
            return
        }

        if let selected = model.selected, let i = handleIndex(at: p, of: selected) {
            dragStartSnapshot = model.snapshot
            drag = .handle(selected.id, index: i)
            return
        }

        switch model.tool {
        case .select:
            if let h = hit(p) {
                model.selectedID = h.id
                startMove(h, from: p)
            } else {
                model.selectedID = nil
                drag = .none
            }

        case .text:
            if wasEditing { return }   // first click outside just commits
            if let h = hit(p), h.kind == .text {
                model.selectedID = h.id
                beginEditing(h.id, isNew: false)
            } else {
                createText(at: p)
            }

        case .step:
            if let h = hit(p), h.kind == .step {
                model.selectedID = h.id
                startMove(h, from: p)
                return
            }
            let pre = model.snapshot
            let step = Annotation(kind: .step, start: p, number: model.nextStepNumber, style: model.style(for: .step))
            model.insert(step)
            model.selectedID = step.id
            model.registerUndo(from: pre)
            startMove(step, from: p)

        default:
            if let selected = model.selected, selected.hitTest(p, tolerance: hitTolerance) {
                startMove(selected, from: p)
                return
            }
            guard let kind = model.tool.kind else { return }
            dragStartSnapshot = model.snapshot
            var a = Annotation(kind: kind, start: p, end: p, style: model.style(for: model.tool))
            if kind == .pen { a.points = [p] }
            model.insert(a)
            drag = .creating(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            break
        case .creating(let id):
            model.update(id) { a in
                if a.kind == .pen {
                    if let last = a.points.last, Geometry.distance(last, p) < 1.5 { return }
                    a.points.append(p)
                    a.end = p
                } else if shift {
                    a.end = (a.kind == .arrow || a.kind == .line)
                        ? Geometry.snapAngle(from: a.start, to: p)
                        : Geometry.snapSquare(from: a.start, to: p)
                } else {
                    a.end = p
                }
            }
        case .moving(let id, let origin, let original):
            model.update(id) { a in
                a = original
                a.translate(dx: p.x - origin.x, dy: p.y - origin.y)
            }
        case .handle(let id, let index):
            model.update(id) { $0.moveHandle(index, to: p) }
        case .cropping(let origin):
            model.cropRect = Geometry.rect(origin, p).intersection(model.imageBounds)
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            dragStartSnapshot = nil
        }
        switch drag {
        case .creating(let id):
            guard let a = model.annotation(id) else { return }
            if a.isDegenerate {
                model.removeSilently(id)
                model.selectedID = nil
                return
            }
            model.selectedID = id
            if let pre = dragStartSnapshot { model.registerUndo(from: pre) }
        case .moving, .handle:
            if let pre = dragStartSnapshot, pre.annotations != model.annotations { model.registerUndo(from: pre) }
        case .cropping:
            if let r = model.cropRect, r.width < 4 || r.height < 4 { model.cropRect = nil }
        case .none:
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let h = hit(point(event)) else { return nil }
        model.selectedID = h.id
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Duplicate") { [weak self] in self?.model.duplicateSelected() })
        menu.addItem(ActionMenuItem("Bring to Front") { [weak self] in self?.model.bringSelectedToFront() })
        menu.addItem(ActionMenuItem("Send to Back") { [weak self] in self?.model.sendSelectedToBack() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.model.deleteSelected() })
        return menu
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 51, 117:   // delete, forward delete
            model.deleteSelected()
            return
        case 53:        // esc
            if model.cropRect != nil { model.cropRect = nil } else { model.selectedID = nil }
            return
        case 36, 76:    // return
            if model.tool == .crop {
                model.applyCrop()
            } else if let s = model.selected, s.kind == .text {
                beginEditing(s.id, isNew: false)
            }
            return
        case 123: model.nudgeSelected(dx: -step, dy: 0); return
        case 124: model.nudgeSelected(dx: step, dy: 0); return
        case 125: model.nudgeSelected(dx: 0, dy: step); return
        case 126: model.nudgeSelected(dx: 0, dy: -step); return
        default: break
        }
        if flags.subtracting(.shift).isEmpty,
           let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.shortcut == ch }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Text editing

    private func createText(at p: CGPoint) {
        let pre = model.snapshot
        var a = Annotation(kind: .text, start: p, style: model.style(for: .text))
        a.start.y -= a.style.fontSize * 0.6   // centre the first line on the click
        TextMetrics.layout(&a)
        model.insert(a)
        model.selectedID = a.id
        beginEditing(a.id, isNew: true, previous: pre)
    }

    private func beginEditing(_ id: UUID, isNew: Bool, previous: EditorModel.Snapshot? = nil) {
        guard let a = model.annotation(id) else { return }
        finishEditing()
        editingID = id
        editingIsNew = isNew
        editingSnapshot = previous ?? model.snapshot

        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = TextMetrics.font(for: a)
        field.textColor = TextMetrics.textColor(for: a)
        field.usesSingleLineMode = false
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        (field.cell as? NSTextFieldCell)?.allowsUndo = false
        field.delegate = self
        addSubview(field)
        textField = field
        layoutTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let id = editingID, let a = model.annotation(id) else { return }
        let p = TextMetrics.padding(for: a)
        let size = TextMetrics.textSize(field.stringValue, for: a)
        field.frame = CGRect(x: a.start.x + p - 2, y: a.start.y + p,
                             width: size.width + a.style.fontSize * 1.5, height: size.height + 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField, let id = editingID else { return }
        model.update(id) { $0.text = field.stringValue }
        layoutTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // ⇧↩ / ⌥↩ add a line; plain ↩ commits.
            if let flags = NSApp.currentEvent?.modifierFlags, !flags.intersection([.shift, .option]).isEmpty {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    private func finishEditing() {
        guard let id = editingID, let field = textField else { return }
        editingID = nil
        textField = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()

        let pre = editingSnapshot
        editingSnapshot = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.removeSilently(id)
            if !editingIsNew, let pre { model.registerUndo(from: pre) }
        } else {
            model.update(id) { $0.text = text }
            if let pre, pre.annotations != model.annotations { model.registerUndo(from: pre) }
        }
        needsDisplay = true
    }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
