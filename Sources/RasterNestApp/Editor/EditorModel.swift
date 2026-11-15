import AppKit
import Combine
import RasterNestCore
import RasterNestRender

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, highlight, text, step, pixelate, spotlight, magnify, pen, crop

    var id: String { rawValue }

    /// The annotation this tool creates (raw values intentionally match).
    var kind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }

    init?(kind: AnnotationKind) { self.init(rawValue: kind.rawValue) }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .highlight: return "Highlighter"
        case .text: return "Text"
        case .step: return "Step"
        case .pixelate: return "Pixelate or Blur"
        case .spotlight: return "Spotlight"
        case .magnify: return "Magnify"
        case .pen: return "Pen"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .spotlight: return "flashlight.on.fill"
        case .magnify: return "plus.magnifyingglass"
        case .pen: return "scribble.variable"
        case .crop: return "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .highlight: return "h"
        case .text: return "t"
        case .step: return "n"
        case .pixelate: return "b"
        case .spotlight: return "s"
        case .magnify: return "m"
        case .pen: return "p"
        case .crop: return "c"
        }
    }

    static func defaultStyles(scale s: CGFloat) -> [Tool: AnnotationStyle] {
        [
            .arrow: AnnotationStyle(color: .red, lineWidth: 4 * s),
            .line: AnnotationStyle(color: .red, lineWidth: 4 * s),
            .rectangle: AnnotationStyle(color: .red, lineWidth: 3 * s),
            .ellipse: AnnotationStyle(color: .red, lineWidth: 3 * s),
            .highlight: AnnotationStyle(color: .yellow, lineWidth: 0, shadow: false, opacity: 0.45),
            .text: AnnotationStyle(color: .red, fontSize: 20 * s, shadow: false),
            .step: AnnotationStyle(color: .red, fontSize: 14 * s),
            .pixelate: AnnotationStyle(color: .black, lineWidth: 10 * s, shadow: false),
            .spotlight: AnnotationStyle(color: .black, lineWidth: 0, shadow: false, opacity: 0.55),
            .magnify: AnnotationStyle(color: .white, lineWidth: 4 * s, shadow: true, zoom: 2),
            .pen: AnnotationStyle(color: .red, lineWidth: 4 * s),
        ]
    }
}

/// Everything about one open capture: image, annotations, tool state and undo.
@MainActor
final class EditorModel: ObservableObject {
    struct Snapshot {
        let image: CGImage
        let annotations: [Annotation]
        var effects: CanvasEffects = .none
    }

    @Published private(set) var image: CGImage
    @Published var annotations: [Annotation]
    @Published var tool: Tool = .arrow {
        didSet { if tool != .crop { cropRect = nil } }
    }
    @Published var selectedID: UUID?
    @Published var cropRect: CGRect?
    @Published var styles: [Tool: AnnotationStyle]
    @Published private(set) var isDirty = false
    @Published private(set) var historyVersion = 0
    @Published var zoomPercent = 100

    let pixelScale: CGFloat
    let undoManager = UndoManager()
    var fileURL: URL?
    private var lastCoalesce: (key: String, time: Date)?

    /// Frame around the capture (padding, background, corners, shadow, border).
    @Published var effects: CanvasEffects = .none

    init(image: CGImage, pixelScale: CGFloat, annotations: [Annotation] = [], fileURL: URL? = nil,
         effects: CanvasEffects = .none) {
        self.effects = effects
        self.image = image
        self.pixelScale = max(1, pixelScale)
        self.annotations = annotations
        self.fileURL = fileURL
        self.styles = Tool.defaultStyles(scale: max(1, pixelScale))
        undoManager.levelsOfUndo = 200
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }
    var selected: Annotation? { selectedID.flatMap(annotation) }
    var snapshot: Snapshot { Snapshot(image: image, annotations: annotations, effects: effects) }

    /// Changes the frame with undo (slider drags merge into one step).
    func updateEffects(coalesce: String, _ body: (inout CanvasEffects) -> Void) {
        checkpoint(coalesce: "effects-\(coalesce)")
        var e = effects
        body(&e)
        effects = e
    }
    var nextStepNumber: Int { Annotation.nextStepNumber(in: annotations) }
    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    func annotation(_ id: UUID) -> Annotation? { annotations.first { $0.id == id } }

    func style(for tool: Tool) -> AnnotationStyle { styles[tool] ?? .standard }

    // MARK: Undo

    /// Records `previous` as an undo step. Calls with the same `coalesce` key within a second merge.
    func registerUndo(from previous: Snapshot, coalesce: String? = nil) {
        if let key = coalesce, let last = lastCoalesce, last.key == key, Date().timeIntervalSince(last.time) < 1 {
            lastCoalesce = (key, Date())
            markChanged()
            return
        }
        lastCoalesce = coalesce.map { ($0, Date()) }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(previous) }
        }
        markChanged()
    }

    /// Call *before* mutating.
    func checkpoint(coalesce: String? = nil) { registerUndo(from: snapshot, coalesce: coalesce) }

    private func restore(_ s: Snapshot) {
        let current = snapshot
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(current) }
        }
        image = s.image
        annotations = s.annotations
        effects = s.effects
        if let id = selectedID, annotation(id) == nil { selectedID = nil }
        cropRect = nil
        lastCoalesce = nil
        markChanged()
    }

    func undo() { if undoManager.canUndo { undoManager.undo() } }
    func redo() { if undoManager.canRedo { undoManager.redo() } }

    private func markChanged() {
        isDirty = true
        historyVersion += 1
    }

    func markSaved() { isDirty = false }

    // MARK: Mutations

    /// Adds without an undo step (callers register one when the gesture ends).
    func insert(_ a: Annotation) { annotations.append(a) }

    /// Places a picture on the capture as a movable, resizable layer (with undo) and selects it.
    /// `scale` is the picture's pixels per point, so a Retina capture dropped on another keeps its size.
    @discardableResult
    func addImageLayer(png: Data, pixelSize: CGSize, scale: CGFloat, center: CGPoint? = nil) -> Annotation {
        let pre = snapshot
        var size = CGSize(width: pixelSize.width * pixelScale / max(scale, 1), height: pixelSize.height * pixelScale / max(scale, 1))
        // Start no bigger than 60% of the capture; corner handles resize it from there.
        let fit = min(1, imageSize.width * 0.6 / size.width, imageSize.height * 0.6 / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        var c = center ?? CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        c.x = min(max(c.x, size.width / 2), imageSize.width - size.width / 2)
        c.y = min(max(c.y, size.height / 2), imageSize.height - size.height / 2)
        let style = AnnotationStyle(color: .white, lineWidth: 0, shadow: true, opacity: 1)
        let layer = Annotation.imageLayer(png: png, center: c, size: size, style: style)
        insert(layer)
        selectedID = layer.id
        tool = .select
        registerUndo(from: pre)
        return layer
    }

    func removeSilently(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        var a = annotations[i]
        body(&a)
        if a.kind == .text { TextMetrics.layout(&a) }
        if a.kind == .image { a = Self.keepInside(a, CGRect(origin: .zero, size: imageSize)) }
        annotations[i] = a
    }

    /// Image layers stay on the capture: shrunk to fit if needed, then slid back inside.
    static func keepInside(_ layer: Annotation, _ bounds: CGRect) -> Annotation {
        var a = layer
        var r = a.rect
        if r.width > bounds.width || r.height > bounds.height {
            let f = min(bounds.width / r.width, bounds.height / r.height)
            r.size = CGSize(width: r.width * f, height: r.height * f)
        }
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        a.start = r.origin
        a.end = CGPoint(x: r.maxX, y: r.maxY)
        return a
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        removeSilently(id)
    }

    func duplicateSelected() {
        guard var copy = selected else { return }
        checkpoint()
        copy.id = UUID()
        copy.translate(dx: 12 * pixelScale, dy: 12 * pixelScale)
        if copy.kind == .step { copy.number = nextStepNumber }
        annotations.append(copy)
        selectedID = copy.id
    }

    /// Moves an annotation to the top without its own undo step (the drag that caused it records one).
    func raiseSilently(_ id: UUID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }), i != annotations.count - 1 else { return }
        let a = annotations.remove(at: i)
        annotations.append(a)
    }

    func bringSelectedToFront() {
        guard let a = selected, let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        checkpoint()
        annotations.remove(at: i)
        annotations.append(a)
    }

    func sendSelectedToBack() {
        guard let a = selected, let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        checkpoint()
        annotations.remove(at: i)
        annotations.insert(a, at: 0)
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let id = selectedID else { return }
        checkpoint(coalesce: "nudge-\(id)")
        update(id) { $0.translate(dx: dx, dy: dy) }
    }

    func applyCrop() {
        guard let rect = cropRect?.integral.intersection(imageBounds),
              rect.width >= 2, rect.height >= 2,
              let cropped = image.cropping(to: rect) else {
            cropRect = nil
            return
        }
        checkpoint()
        image = cropped
        for i in annotations.indices { annotations[i].translate(dx: -rect.minX, dy: -rect.minY) }
        cropRect = nil
        tool = .select
    }

    // MARK: Inspector

    /// The kind whose properties the inspector shows: the selection, else the current tool.
    var inspectedKind: AnnotationKind? { selected?.kind ?? tool.kind }

    var inspectedStyle: AnnotationStyle { selected?.style ?? style(for: tool) }

    /// Edits the selection's style (with undo) and remembers it as that tool's default.
    func updateInspectedStyle(coalesce: String, _ body: (inout AnnotationStyle) -> Void) {
        if let sel = selected {
            checkpoint(coalesce: "style-\(coalesce)-\(sel.id)")
            var style = sel.style
            body(&style)
            update(sel.id) { $0.style = style }
            if let t = Tool(kind: sel.kind) { styles[t] = style }
        } else {
            var style = inspectedStyle
            body(&style)
            styles[tool] = style
        }
    }

    // MARK: Output

    func flattened() -> CGImage? {
        AnnotationRenderer(unit: pixelScale).flatten(image: image, annotations: annotations, effects: effects)
    }

    func makeDocument() -> NestDocument? {
        ImageCodec.makeDocument(image: image, scale: pixelScale, annotations: annotations,
                                effects: effects.isEmpty ? nil : effects)
    }
}
