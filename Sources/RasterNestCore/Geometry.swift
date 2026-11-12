import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ArrowHead: Equatable, Sendable {
    public var tip: CGPoint
    public var base: CGPoint
    public var left: CGPoint
    public var right: CGPoint
}

/// Pure geometry helpers shared by the renderer, hit testing and tests.
public enum Geometry {
    public static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Shortest distance from `p` to the segment `a`–`b`.
    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    public static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Arrow head triangle for an arrow from `start` to `end`. The shaft should be drawn to `base`.
    public static func arrowHead(start: CGPoint, end: CGPoint, lineWidth: CGFloat) -> ArrowHead {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let ux = dx / length, uy = dy / length
        let headLength = min(length, max(lineWidth * 3.2, 10))
        let halfWidth = max(headLength * 0.55, lineWidth)
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let left = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        let right = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        return ArrowHead(tip: end, base: base, left: left, right: right)
    }

    /// Snaps the segment `start`→`end` to the nearest 45° angle, preserving length.
    public static func snapAngle(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// Constrains the rectangle spanned by `start`→`end` to a square.
    public static func snapSquare(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }
}
