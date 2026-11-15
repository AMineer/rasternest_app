import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where each image goes when several are combined into one (side by side, stacked or a grid).
/// Pure geometry so it's shared by the app, `rnest combine` and tests.
public struct CombineLayout: Equatable, Sendable {
    public enum Arrangement: String, Codable, CaseIterable, Sendable {
        case horizontal, vertical, grid

        public var title: String {
            switch self {
            case .horizontal: return "Side by Side"
            case .vertical: return "Stacked"
            case .grid: return "Grid"
            }
        }
    }

    public var arrangement: Arrangement
    /// Space between images, in output pixels.
    public var gap: CGFloat
    /// Space around the outside, in output pixels.
    public var padding: CGFloat
    /// Grid columns; nil picks a near-square grid.
    public var columns: Int?
    /// Scale images so rows share a height (side by side), columns share a width (stacked),
    /// or every image fills the same cell (grid). Without it, images keep their size and are centered.
    public var matchSizes: Bool

    public init(arrangement: Arrangement = .horizontal, gap: CGFloat = 24, padding: CGFloat = 0,
                columns: Int? = nil, matchSizes: Bool = true) {
        self.arrangement = arrangement; self.gap = gap; self.padding = padding
        self.columns = columns; self.matchSizes = matchSizes
    }

    public struct Result: Equatable, Sendable {
        public var canvas: CGSize
        public var frames: [CGRect]
    }

    /// Frames (origin top-left) for images of the given pixel sizes.
    public func place(_ sizes: [CGSize]) -> Result {
        let sizes = sizes.map { CGSize(width: max(1, $0.width), height: max(1, $0.height)) }
        guard !sizes.isEmpty else { return Result(canvas: .zero, frames: []) }
        var frames: [CGRect] = []

        switch arrangement {
        case .horizontal:
            let h = matchSizes ? sizes.map(\.height).max()! : 0
            let scaled = sizes.map { matchSizes ? CGSize(width: $0.width * h / $0.height, height: h) : $0 }
            let rowH = scaled.map(\.height).max()!
            var x = padding
            for s in scaled {
                frames.append(CGRect(x: x, y: padding + (rowH - s.height) / 2, width: s.width, height: s.height))
                x += s.width + gap
            }
            return Result(canvas: CGSize(width: x - gap + padding, height: rowH + padding * 2), frames: frames.map(\.integral))

        case .vertical:
            let w = matchSizes ? sizes.map(\.width).max()! : 0
            let scaled = sizes.map { matchSizes ? CGSize(width: w, height: $0.height * w / $0.width) : $0 }
            let colW = scaled.map(\.width).max()!
            var y = padding
            for s in scaled {
                frames.append(CGRect(x: padding + (colW - s.width) / 2, y: y, width: s.width, height: s.height))
                y += s.height + gap
            }
            return Result(canvas: CGSize(width: colW + padding * 2, height: y - gap + padding), frames: frames.map(\.integral))

        case .grid:
            let cols = max(1, min(columns ?? Int(Double(sizes.count).squareRoot().rounded(.up)), sizes.count))
            let rows = Int((Double(sizes.count) / Double(cols)).rounded(.up))
            let cell = CGSize(width: sizes.map(\.width).max()!, height: sizes.map(\.height).max()!)
            for (i, s) in sizes.enumerated() {
                let col = i % cols, row = i / cols
                let origin = CGPoint(x: padding + CGFloat(col) * (cell.width + gap), y: padding + CGFloat(row) * (cell.height + gap))
                // Fit inside the cell keeping aspect ratio; only grow when matching sizes.
                var f = min(cell.width / s.width, cell.height / s.height)
                if !matchSizes { f = min(f, 1) }
                let fitted = CGSize(width: s.width * f, height: s.height * f)
                frames.append(CGRect(x: origin.x + (cell.width - fitted.width) / 2, y: origin.y + (cell.height - fitted.height) / 2,
                                     width: fitted.width, height: fitted.height))
            }
            let canvas = CGSize(width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * gap + padding * 2,
                                height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap + padding * 2)
            return Result(canvas: canvas, frames: frames.map(\.integral))
        }
    }
}
