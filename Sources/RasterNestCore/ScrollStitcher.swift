import Foundation

/// A compact fingerprint of a frame: for every pixel row, the mean brightness of `bands`
/// vertical bands. Comparing fingerprints is far cheaper than comparing pixels, and it is
/// platform-neutral so the same stitcher can serve macOS, Linux or Windows capture code.
public struct RowSignature: Equatable, Sendable {
    public let rows: Int
    public let bands: Int
    /// `rows * bands` values in 0...255, row-major.
    public var values: [Float]

    public init(rows: Int, bands: Int, values: [Float]) {
        precondition(values.count == rows * bands, "values must hold rows * bands entries")
        self.rows = rows
        self.bands = bands
        self.values = values
    }

    /// Mean absolute difference between row `r` of `self` and row `s` of `other`.
    @inline(__always)
    func rowDistance(_ r: Int, _ other: RowSignature, _ s: Int) -> Float {
        var sum: Float = 0
        let a = r * bands, b = s * other.bands
        for i in 0..<bands { sum += abs(values[a + i] - other.values[b + i]) }
        return sum / Float(bands)
    }
}

/// Works out how a scrolling region moved between frames.
public enum ScrollMatcher {
    /// Rows at the top and bottom that are unchanged between two frames (sticky toolbars,
    /// headers, footers). Each side is capped at 40% of the frame.
    public static func staticEdges(_ a: RowSignature, _ b: RowSignature, tolerance: Float) -> (top: Int, bottom: Int) {
        precondition(a.rows == b.rows && a.bands == b.bands)
        let cap = Int(Double(a.rows) * 0.4)
        var top = 0
        while top < cap && a.rowDistance(top, b, top) <= tolerance { top += 1 }
        var bottom = 0
        while bottom < cap && a.rowDistance(a.rows - 1 - bottom, b, a.rows - 1 - bottom) <= tolerance { bottom += 1 }
        return (top, bottom)
    }

    /// How many pixels the content moved *up* from `previous` to `current`, comparing only
    /// rows in `[top, rows - bottom)`. Returns nil when no offset matches confidently
    /// (scrolled up, scrolled too fast, or the content changed), 0 when nothing moved.
    public static func offset(previous: RowSignature, current: RowSignature, top: Int, bottom: Int,
                              minOverlapFraction: Double = 0.2, tolerance: Float = 3) -> Int? {
        let body = previous.rows - top - bottom
        let minOverlap = max(8, Int(Double(body) * minOverlapFraction))
        guard body > minOverlap else { return nil }
        let maxShift = body - minOverlap

        var costs = [Float](repeating: .infinity, count: maxShift + 1)
        var best: Float = .infinity
        for dy in 0...maxShift {
            let overlap = body - dy
            // Sample ~300 rows of the overlap: plenty to be confident, cheap enough for 12 fps.
            let stride = max(1, overlap / 300)
            var sum: Float = 0, count: Float = 0
            var r = 0
            while r < overlap {
                // current row (top + r) should equal previous row (top + r + dy)
                sum += current.rowDistance(top + r, previous, top + r + dy)
                count += 1
                // Early exit: already worse than the best candidate by a wide margin.
                if count >= 24 && sum / count > best * 4 + tolerance * 4 { sum = .infinity; break }
                r += stride
            }
            let cost = sum / max(count, 1)
            costs[dy] = cost
            best = min(best, cost)
        }
        guard best <= tolerance else { return nil }
        // Prefer the smallest shift that is about as good as the best one: real frame-to-frame
        // scrolls are small, and repeating content (list rows) can match at multiples.
        let slack = max(tolerance * 0.35, best * 0.5)
        return costs.firstIndex { $0 <= best + slack }
    }
}

/// Decides, frame by frame, which rows to keep to build one tall image.
///
/// The output is: the first frame (minus any sticky footer), then every appended strip,
/// then the sticky footer taken from the last accepted frame.
public struct ScrollStitcher: Sendable {
    public enum Step: Equatable, Sendable {
        /// The first frame: keep all of it.
        case first
        /// Keep `count` rows of this frame starting at row `from`.
        case append(from: Int, count: Int)
        /// Nothing new (no movement, scrolled up, or no confident match).
        case skip
    }

    public private(set) var reference: RowSignature?
    /// Sticky rows at the top / bottom, fixed once the first real scroll is seen.
    public private(set) var header = 0
    public private(set) var footer = 0
    public private(set) var edgesLocked = false
    /// Rows in the stitched image so far, not counting the footer added at the end.
    public private(set) var bodyHeight = 0
    /// Consecutive frames that changed but couldn't be matched (e.g. scrolling too fast).
    public private(set) var mismatchStreak = 0

    public let tolerance: Float
    public let minOverlapFraction: Double

    public init(tolerance: Float = 3, minOverlapFraction: Double = 0.2) {
        self.tolerance = tolerance
        self.minOverlapFraction = minOverlapFraction
    }

    /// Total height of the image if finished now.
    public var totalHeight: Int { bodyHeight + footer }

    public mutating func add(_ sig: RowSignature) -> Step {
        guard let ref = reference else {
            reference = sig
            bodyHeight = sig.rows
            return .first
        }
        guard sig.rows == ref.rows, sig.bands == ref.bands else { return .skip }

        var top = header, bottom = footer
        if !edgesLocked {
            let edges = ScrollMatcher.staticEdges(ref, sig, tolerance: tolerance * 0.5)
            if edges.top + edges.bottom >= sig.rows - 8 {
                // Identical frame.
                return .skip
            }
            top = edges.top
            bottom = edges.bottom
        }

        guard let dy = ScrollMatcher.offset(previous: ref, current: sig, top: top, bottom: bottom,
                                            minOverlapFraction: minOverlapFraction, tolerance: tolerance) else {
            mismatchStreak += 1
            return .skip
        }
        mismatchStreak = 0
        guard dy > 0 else { return .skip }

        if !edgesLocked {
            header = top
            footer = bottom
            edgesLocked = true
            // The first frame's footer rows move to the very end of the image.
            bodyHeight = ref.rows - footer
        }
        reference = sig
        bodyHeight += dy
        return .append(from: sig.rows - footer - dy, count: dy)
    }
}
