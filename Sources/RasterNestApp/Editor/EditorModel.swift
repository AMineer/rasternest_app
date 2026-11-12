import AppKit
import Combine
import RasterNestCore
import RasterNestRender

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, highlight, text, step, pixelate, spotlight, pen, crop

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
        case .pixelate: return "Pixelate"
        case .spotlight: return "Spotlight"
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

    func removeSilently(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        var a = annotations[i]
        body(&a)
        if a.kind == .text { TextMetrics.layout(&a) }
        annotations[i] = a
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
