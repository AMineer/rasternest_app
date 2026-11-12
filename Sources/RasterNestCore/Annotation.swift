import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case arrow, line, rectangle, ellipse, highlight, text, step, pixelate, spotlight, pen

    /// Kinds whose geometry is the rectangle spanned by `start` and `end`.
    public var isBoxed: Bool {
        switch self {
        case .rectangle, .ellipse, .highlight, .pixelate, .spotlight, .text: return true
        case .arrow, .line, .step, .pen: return false
        }
    }
}

public struct AnnotationStyle: Codable, Hashable, Sendable {
    /// Main color: stroke for shapes, text color, fill for steps and callouts.
    public var color: RGBA
    /// Stroke width in image pixels. For `.pixelate` this is the block size.
    public var lineWidth: CGFloat
    /// Font size in image pixels (text and step numbers).
    public var fontSize: CGFloat
    /// Shapes get a translucent fill; text becomes a filled callout.
    public var filled: Bool
    public var shadow: Bool
    /// Highlighter opacity / spotlight dim amount.
    public var opacity: CGFloat

    public init(color: RGBA = .red, lineWidth: CGFloat = 4, fontSize: CGFloat = 22,
                filled: Bool = false, shadow: Bool = true, opacity: CGFloat = 1) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.filled = filled
        self.shadow = shadow
        self.opacity = opacity
    }

    public static let standard = AnnotationStyle()
}

/// A single markup object. All coordinates are in image pixels, origin top-left, y down.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var start: CGPoint
    public var end: CGPoint
    /// Freehand points (pen only).
    public var points: [CGPoint]
    public var text: String
    /// Step number (step only).
    public var number: Int
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), kind: AnnotationKind, start: CGPoint, end: CGPoint? = nil,
                points: [CGPoint] = [], text: String = "", number: Int = 0,
                style: AnnotationStyle = .standard) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.points = points
        self.text = text
        self.number = number
        self.style = style
    }

    public var rect: CGRect { Geometry.rect(start, end) }

    public var stepRadius: CGFloat { max(style.fontSize * 0.85, 8) }

    /// Visual bounds, used for selection outlines.
    public var bounds: CGRect {
        let pad = style.lineWidth / 2 + 1
        switch kind {
        case .pen:
            return Geometry.boundingBox(points).insetBy(dx: -pad, dy: -pad)
        case .step:
            let r = stepRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .arrow, .line, .rectangle, .ellipse:
            return rect.insetBy(dx: -pad, dy: -pad)
        case .text, .highlight, .pixelate, .spotlight:
            return rect
        }
    }

    /// True when the annotation is too small to be meaningful (e.g. a click without a drag).
    public var isDegenerate: Bool {
        switch kind {
        case .pen: return points.count < 2
        case .step, .text: return false
        default: return abs(end.x - start.x) < 3 && abs(end.y - start.y) < 3
        }
    }

    public func hitTest(_ p: CGPoint, tolerance: CGFloat = 4) -> Bool {
        let tol = tolerance + style.lineWidth / 2
        switch kind {
        case .arrow, .line:
            return Geometry.distance(from: p, toSegment: start, end) <= tol
        case .pen:
            guard points.count > 1 else { return points.first.map { Geometry.distance(p, $0) <= tol } ?? false }
            for i in 1..<points.count where Geometry.distance(from: p, toSegment: points[i - 1], points[i]) <= tol {
                return true
            }
            return false
        case .rectangle:
            let outer = rect.insetBy(dx: -tol, dy: -tol)
            guard outer.contains(p) else { return false }
            if style.filled { return true }
            let inner = rect.insetBy(dx: tol, dy: tol)
            return inner.isNull || inner.isEmpty || !inner.contains(p)
        case .ellipse:
            let r = rect
            let rx = r.width / 2, ry = r.height / 2
            guard rx > 0.5, ry > 0.5 else { return r.insetBy(dx: -tol, dy: -tol).contains(p) }
            let dx = (p.x - r.midX) / rx, dy = (p.y - r.midY) / ry
            let v = (dx * dx + dy * dy).squareRoot()
            if style.filled && v <= 1 { return true }
            return abs(v - 1) * min(rx, ry) <= tol
        case .highlight, .pixelate, .spotlight, .text:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .step:
            return Geometry.distance(p, start) <= stepRadius + tolerance
        }
    }

    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        for i in points.indices {
            points[i].x += dx
            points[i].y += dy
        }
    }

    /// Draggable handles. Lines/arrows: [start, end]. Boxes: four corners.
    public var handles: [CGPoint] {
        switch kind {
        case .arrow, .line:
            return [start, end]
        case .rectangle, .ellipse, .highlight, .pixelate, .spotlight:
            return [start, end, CGPoint(x: start.x, y: end.y), CGPoint(x: end.x, y: start.y)]
        case .text, .step, .pen:
            return []
        }
    }

    public mutating func moveHandle(_ index: Int, to p: CGPoint) {
        switch index {
        case 0: start = p
        case 1: end = p
        case 2: start.x = p.x; end.y = p.y
        case 3: end.x = p.x; start.y = p.y
        default: break
        }
    }

    /// Next number for the step tool: one more than the highest existing step.
    public static func nextStepNumber(in annotations: [Annotation]) -> Int {
        (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
    }
}
