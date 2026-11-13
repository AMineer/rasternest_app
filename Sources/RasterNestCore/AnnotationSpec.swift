import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A declarative description of markup: "step 1 on Save, arrow to Allow, redact emails".
///
/// Positions are anchors: a piece of text found by OCR, a point, or a rectangle, all in image
/// pixels (origin top-left). `AnnotationSpec.resolve` turns a spec into concrete `Annotation`s.
///
/// ```json
/// {
///   "frame": "docs",
///   "annotations": [
///     { "type": "step",   "at": { "text": "Save" } },
///     { "type": "arrow",  "to": { "text": "Allow" }, "label": "Then allow access" },
///     { "type": "box",    "around": { "text": "Advanced" } },
///     { "type": "redact", "pattern": "email" }
///   ]
/// }
/// ```
public struct AnnotationSpec: Codable, Equatable, Sendable {
    /// `none` or `docs` (padding, gradient background, rounded corners, shadow).
    public var frame: String?
    /// Default color for annotations that don't set one.
    public var color: String?
    public var annotations: [Item]

    public init(frame: String? = nil, color: String? = nil, annotations: [Item]) {
        self.frame = frame; self.color = color; self.annotations = annotations
    }

    /// Where an annotation goes. Exactly one of `text`, `point` (x and y) or `rect` is used.
    public struct Anchor: Codable, Equatable, Sendable {
        public var text: String?
        /// Which match of `text` to use, 1-based, best matches first.
        public var occurrence: Int?
        public var x: Double?
        public var y: Double?
        /// [x, y, width, height]
        public var rect: [Double]?

        public init(text: String? = nil, occurrence: Int? = nil, x: Double? = nil, y: Double? = nil, rect: [Double]? = nil) {
            self.text = text; self.occurrence = occurrence; self.x = x; self.y = y; self.rect = rect
        }

        public var needsOCR: Bool { text != nil }
    }

    public struct Item: Codable, Equatable, Sendable {
        /// step, arrow, line, box (rectangle), ellipse, highlight, text, pixelate, redact, spotlight, magnify
        public var type: String
        /// Steps and text labels: where to place it. Boxes: same as `around`.
        public var at: Anchor?
        /// Boxed kinds: the thing to surround.
        public var around: Anchor?
        /// Arrows and lines: the start. Defaults to a spot beside the target toward the image center.
        public var from: Anchor?
        /// Arrows and lines: the target.
        public var to: Anchor?
        /// Text for `text` annotations; for steps and arrows, an optional label placed next to it.
        public var text: String?
        public var label: String?
        /// Step number. Defaults to counting up from 1.
        public var number: Int?
        /// Redaction: email, phone, ipv4, url, card, token.
        public var pattern: String?
        /// Redaction: a custom regular expression.
        public var regex: String?
        /// Redaction: literal text to hide wherever it appears.
        public var match: String?
        /// Color name (red, orange, yellow, green, blue, purple, black, white) or #RRGGBB.
        public var color: String?
        /// Extra space around a matched anchor, in points.
        public var padding: Double?
        /// Line width in points.
        public var width: Double?
        /// Font size in points.
        public var size: Double?
        /// Magnify zoom (2 = 200%).
        public var zoom: Double?
        /// Text: draw as a filled callout (default true).
        public var callout: Bool?
        /// Shapes: translucent fill.
        public var filled: Bool?

        public init(type: String, at: Anchor? = nil, around: Anchor? = nil, from: Anchor? = nil, to: Anchor? = nil,
                    text: String? = nil, label: String? = nil, number: Int? = nil, pattern: String? = nil,
                    regex: String? = nil, match: String? = nil, color: String? = nil, padding: Double? = nil,
                    width: Double? = nil, size: Double? = nil, zoom: Double? = nil, callout: Bool? = nil, filled: Bool? = nil) {
            self.type = type; self.at = at; self.around = around; self.from = from; self.to = to
            self.text = text; self.label = label; self.number = number; self.pattern = pattern
            self.regex = regex; self.match = match; self.color = color; self.padding = padding
            self.width = width; self.size = size; self.zoom = zoom; self.callout = callout; self.filled = filled
        }

        var anchors: [Anchor] { [at, around, from, to].compactMap { $0 } }
    }

    public enum ResolveError: LocalizedError, Equatable {
        case unknownType(String)
        case missingAnchor(type: String, field: String)
        case textNotFound(String, seen: [String])
        case badAnchor(String)
        case badPattern(String)
        case badColor(String)
        case badFrame(String)

        public var errorDescription: String? {
            switch self {
            case .unknownType(let t):
                return "Unknown annotation type `\(t)`. Use step, arrow, line, box, ellipse, highlight, text, pixelate, redact, spotlight or magnify."
            case .missingAnchor(let t, let f): return "`\(t)` needs `\(f)`."
            case .textNotFound(let t, let seen):
                let sample = seen.prefix(25).map { "\"\($0)\"" }.joined(separator: ", ")
                return "Couldn't find the text \"\(t)\" in the image." + (seen.isEmpty ? " No text was recognized." : " Text found: \(sample)")
            case .badAnchor(let m): return m
            case .badPattern(let p): return "Unknown redaction pattern `\(p)`. Use email, phone, ipv4, url, card or token, or give `regex`."
            case .badColor(let c): return "Unknown color `\(c)`. Use a name like red or blue, or #RRGGBB."
            case .badFrame(let f): return "Unknown frame `\(f)`. Use none or docs."
            }
        }
    }

    /// True when any anchor or redaction needs recognized text.
    public var needsOCR: Bool {
        annotations.contains { item in
            item.anchors.contains(where: \.needsOCR) || item.type.lowercased() == "redact"
        }
    }

    /// The frame to apply, or nil to leave the document's frame as it is.
    public func effects(scale: CGFloat) throws -> CanvasEffects? {
        guard let frame else { return nil }
        switch frame.lowercased() {
        case "none", "": return CanvasEffects.none
        case "docs", "documentation": return .documentation(scale: scale)
        default: throw ResolveError.badFrame(frame)
        }
    }

    /// Concrete annotations for an image of `size` pixels at `scale` pixels per point.
    /// `startingStep` continues numbering after steps that already exist.
    public func resolve(imageSize size: CGSize, scale: CGFloat, lines: [TextLine], startingStep: Int = 1) throws -> [Annotation] {
        let s = max(1, scale)
        let bounds = CGRect(origin: .zero, size: size)
        var out: [Annotation] = []
        var nextStep = startingStep
        let defaultColor = try color.map(Self.parseColor) ?? .red

        func box(_ a: Anchor, pad: CGFloat) throws -> CGRect {
            if let text = a.text {
                guard let found = TextMatcher.find(text, in: lines, occurrence: a.occurrence ?? 1) else {
                    throw ResolveError.textNotFound(text, seen: TextMatcher.readingOrder(lines).map(\.text))
                }
                return found.rect.insetBy(dx: -pad, dy: -pad).intersection(bounds)
            }
            if let r = a.rect {
                guard r.count == 4, r[2] > 0, r[3] > 0 else { throw ResolveError.badAnchor("`rect` must be [x, y, width, height].") }
                return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
            }
            if let x = a.x, let y = a.y {
                return CGRect(x: x, y: y, width: 0, height: 0).insetBy(dx: -pad, dy: -pad)
            }
            throw ResolveError.badAnchor("An anchor needs `text`, `x` and `y`, or `rect`.")
        }

        for item in annotations {
            let type = item.type.lowercased()
            var color = try item.color.map(Self.parseColor) ?? defaultColor
            let pad = CGFloat(item.padding ?? 6) * s
            let anchor = item.around ?? item.at ?? item.to

            switch type {
            case "step":
                guard let a = item.at ?? item.around ?? item.to else { throw ResolveError.missingAnchor(type: type, field: "at") }
                let target = try box(a, pad: 0)
                let style = AnnotationStyle(color: color, fontSize: CGFloat(item.size ?? 14) * s)
                let r = max(style.fontSize * 0.85, 8)
                let gap = 8 * s
                // Left of the target, vertically centered; to the right when there's no room.
                var center = CGPoint(x: target.minX - gap - r, y: target.midY)
                if a.text == nil && a.rect == nil { center = target.center }
                else if center.x - r < 0 { center.x = min(size.width - r, target.maxX + gap + r) }
                let n = item.number ?? nextStep
                nextStep = n + 1
                out.append(Annotation(kind: .step, start: center, number: n, style: style))
                if let label = item.label ?? item.text {
                    out.append(makeLabel(label, near: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
                                     color: color, size: item.size, s: s, bounds: bounds))
                }

            case "arrow", "line":
                guard let toA = item.to ?? item.at ?? item.around else { throw ResolveError.missingAnchor(type: type, field: "to") }
                let target = try box(toA, pad: 4 * s)
                let start: CGPoint
                if let fromA = item.from {
                    start = try box(fromA, pad: 0).center
                } else {
                    start = Self.arrowStart(toward: target, in: bounds, length: 110 * s)
                }
                let end = (toA.text != nil || toA.rect != nil) ? Self.edgePoint(of: target, from: start) : target.center
                let style = AnnotationStyle(color: color, lineWidth: CGFloat(item.width ?? 4) * s)
                out.append(Annotation(kind: type == "arrow" ? .arrow : .line, start: start, end: end, style: style))
                if let label = item.label ?? item.text {
                    out.append(makeLabel(label, near: CGRect(origin: start, size: .zero), color: color, size: item.size, s: s, bounds: bounds))
                }

            case "box", "rectangle", "rect", "ellipse", "circle", "highlight", "pixelate", "blur", "spotlight", "magnify":
                guard let a = anchor else { throw ResolveError.missingAnchor(type: type, field: "around") }
                let r = try box(a, pad: pad)
                let kind: AnnotationKind
                var style: AnnotationStyle
                switch type {
                case "ellipse", "circle":
                    kind = .ellipse
                    style = AnnotationStyle(color: color, lineWidth: CGFloat(item.width ?? 3) * s, filled: item.filled ?? false)
                case "highlight":
                    kind = .highlight
                    if item.color == nil { color = .yellow }
                    style = AnnotationStyle(color: color, lineWidth: 0, shadow: false, opacity: 0.45)
                case "pixelate", "blur":
                    kind = .pixelate
                    style = AnnotationStyle(color: .black, lineWidth: CGFloat(item.width ?? 10) * s, shadow: false)
                case "spotlight":
                    kind = .spotlight
                    style = AnnotationStyle(color: .black, lineWidth: 0, shadow: false, opacity: 0.55)
                case "magnify":
                    kind = .magnify
                    style = AnnotationStyle(color: item.color == nil ? .white : color, lineWidth: CGFloat(item.width ?? 4) * s,
                                            shadow: true, zoom: CGFloat(item.zoom ?? 2))
                default:
                    kind = .rectangle
                    style = AnnotationStyle(color: color, lineWidth: CGFloat(item.width ?? 3) * s, filled: item.filled ?? false)
                }
                out.append(Annotation(kind: kind, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), style: style))
                if let label = item.label, kind == .rectangle || kind == .ellipse || kind == .highlight {
                    out.append(makeLabel(label, near: r, color: color, size: item.size, s: s, bounds: bounds))
                }

            case "text", "label", "callout":
                guard let text = item.text ?? item.label else { throw ResolveError.missingAnchor(type: type, field: "text") }
                guard let a = item.at ?? item.around ?? item.to else { throw ResolveError.missingAnchor(type: type, field: "at") }
                let target = try box(a, pad: 0)
                var ann = makeLabel(text, near: target, color: color, size: item.size, s: s, bounds: bounds)
                if a.text == nil && a.rect == nil { ann.start = target.center; ann.end = ann.start }
                ann.style.filled = item.callout ?? true
                out.append(ann)

            case "redact":
                var boxes: [PixelBox] = []
                if let p = item.pattern {
                    guard let pattern = RedactionPattern(rawValue: p.lowercased()) else { throw ResolveError.badPattern(p) }
                    boxes += TextMatcher.boxes(matching: pattern.regex, in: lines)
                }
                if let rx = item.regex {
                    guard let regex = try? NSRegularExpression(pattern: rx) else { throw ResolveError.badPattern(rx) }
                    boxes += TextMatcher.boxes(matching: regex, in: lines)
                }
                if let m = item.match { boxes += TextMatcher.matches(of: m, in: lines) }
                if let a = item.around ?? item.at { boxes.append(PixelBox(try box(a, pad: 0))) }
                if item.pattern == nil && item.regex == nil && item.match == nil && item.around == nil && item.at == nil {
                    throw ResolveError.missingAnchor(type: type, field: "pattern, regex, match or around")
                }
                let style = AnnotationStyle(color: .black, lineWidth: CGFloat(item.width ?? 10) * s, shadow: false)
                for b in boxes {
                    let r = b.rect.insetBy(dx: -3 * s, dy: -3 * s).intersection(bounds)
                    guard !r.isNull, r.width > 0 else { continue }
                    out.append(Annotation(kind: .pixelate, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY), style: style))
                }

            default:
                throw ResolveError.unknownType(item.type)
            }
        }
        return out
    }

    // MARK: placement helpers

    /// A text callout beside `target`: below it when there's room, otherwise above.
    private func makeLabel(_ text: String, near target: CGRect, color: RGBA, size: Double?, s: CGFloat, bounds: CGRect) -> Annotation {
        let fontSize = CGFloat(size ?? 16) * s
        let estWidth = min(bounds.width, CGFloat(text.count) * fontSize * 0.58 + fontSize)
        let lineH = fontSize * 1.6
        var origin = CGPoint(x: target.minX, y: target.maxY + 8 * s)
        if origin.y + lineH > bounds.maxY { origin.y = max(0, target.minY - 8 * s - lineH) }
        origin.x = max(0, min(origin.x, bounds.maxX - estWidth))
        var style = AnnotationStyle(color: color, fontSize: fontSize, filled: true, shadow: false)
        style.lineWidth = 0
        return Annotation(kind: .text, start: origin, end: CGPoint(x: origin.x + estWidth, y: origin.y + lineH), text: text, style: style)
    }

    /// A start point `length` away from `target`, heading toward the middle of the image so the arrow has room.
    static func arrowStart(toward target: CGRect, in bounds: CGRect, length: CGFloat) -> CGPoint {
        let c = target.center
        var dx = bounds.midX - c.x, dy = bounds.midY - c.y
        if abs(dx) < 1 && abs(dy) < 1 { dx = 1; dy = 1 }
        // Prefer a diagonal approach; it reads as "pointing at" better than a flat one.
        let sx: CGFloat = dx >= 0 ? 1 : -1, sy: CGFloat = dy >= 0 ? 1 : -1
        let d = length / 2.squareRoot()
        let edge = edgePoint(of: target, from: CGPoint(x: c.x + sx * 1000, y: c.y + sy * 1000))
        var p = CGPoint(x: edge.x + sx * d, y: edge.y + sy * d)
        p.x = max(bounds.minX + 4, min(p.x, bounds.maxX - 4))
        p.y = max(bounds.minY + 4, min(p.y, bounds.maxY - 4))
        return p
    }

    /// Where the line from `p` to the rectangle's center crosses its edge.
    static func edgePoint(of r: CGRect, from p: CGPoint) -> CGPoint {
        let c = r.center
        let dx = p.x - c.x, dy = p.y - c.y
        guard r.width > 0 || r.height > 0, dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.infinity : (r.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (r.height / 2) / abs(dy)
        let t = min(tx, ty, 1)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    public static func parseColor(_ s: String) throws -> RGBA {
        let named: [String: RGBA] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green,
                                     "blue": .blue, "purple": .purple, "violet": .purple, "black": .black, "white": .white]
        let key = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = named[key] { return c }
        var hex = key.hasPrefix("#") ? String(key.dropFirst()) : key
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { throw ResolveError.badColor(s) }
        return RGBA(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
