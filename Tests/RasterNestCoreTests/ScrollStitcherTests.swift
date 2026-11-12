import XCTest
@testable import RasterNestCore

/// Simulates a scrolling window over a tall page whose rows have unique fingerprints, then checks
/// that the stitched output (as row identities) is the page exactly once, in order.
final class ScrollStitcherTests: XCTestCase {
    let bands = 8
    let frameRows = 240

    /// Deterministic pseudo-random row fingerprints.
    func page(rows: Int, seed: UInt64) -> [[Float]] {
        var state = seed
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) % 256)
        }
        return (0..<rows).map { _ in (0..<bands).map { _ in next() } }
    }

    struct Frame { let sig: RowSignature; let ids: [Int] }

    /// A frame showing page rows [offset, offset + body), with optional sticky header/footer rows.
    func frame(_ page: [[Float]], offset: Int, header: [[Float]] = [], footer: [[Float]] = []) -> Frame {
        let body = frameRows - header.count - footer.count
        var rows: [[Float]] = header
        var ids: [Int] = header.indices.map { -1000 - $0 }
        rows += page[offset..<(offset + body)]
        ids += Array(offset..<(offset + body))
        rows += footer
        ids += footer.indices.map { -2000 - $0 }
        return Frame(sig: RowSignature(rows: frameRows, bands: bands, values: rows.flatMap { $0 }), ids: ids)
    }

    /// Runs the stitcher and assembles row identities the same way the app assembles pixels.
    func stitch(_ frames: [Frame]) -> (ids: [Int], stitcher: ScrollStitcher) {
        var stitcher = ScrollStitcher()
        var first: [Int] = []
        var strips: [Int] = []
        var last: [Int] = []
        for f in frames {
            switch stitcher.add(f.sig) {
            case .first: first = f.ids; last = f.ids
            case .append(let from, let count): strips += f.ids[from..<(from + count)]; last = f.ids
            case .skip: break
            }
        }
        let rows = frameRows
        let ids = Array(first[0..<(rows - stitcher.footer)]) + strips + Array(last[(rows - stitcher.footer)..<rows])
        XCTAssertEqual(ids.count, stitcher.totalHeight)
        return (ids, stitcher)
    }

    func testPlainScrollIncludingPauses() {
        let p = page(rows: 2000, seed: 1)
        let offsets = [0, 0, 37, 80, 80, 150, 151, 300, 420, 421, 600]
        let (ids, _) = stitch(offsets.map { frame(p, offset: $0) })
        XCTAssertEqual(ids, Array(0..<(600 + frameRows)))
    }

    func testStickyHeaderAndFooterAppearOnce() {
        let p = page(rows: 2000, seed: 2)
        let header = page(rows: 20, seed: 3)
        let footer = page(rows: 15, seed: 4)
        let body = frameRows - 35
        let offsets = [0, 40, 90, 160, 161, 230]
        let (ids, stitcher) = stitch(offsets.map { frame(p, offset: $0, header: header, footer: footer) })
        XCTAssertEqual(stitcher.header, 20)
        XCTAssertEqual(stitcher.footer, 15)
        let expected = (0..<20).map { -1000 - $0 } + Array(0..<(230 + body)) + (0..<15).map { -2000 - $0 }
        XCTAssertEqual(ids, expected)
    }

    func testScrollingBackUpIsIgnored() {
        let p = page(rows: 2000, seed: 5)
        let offsets = [0, 60, 120, 70, 20, 90, 180]
        let (ids, _) = stitch(offsets.map { frame(p, offset: $0) })
        XCTAssertEqual(ids, Array(0..<(180 + frameRows)))
    }

    func testJumpTooFarIsSkippedAndReported() {
        let p = page(rows: 3000, seed: 6)
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(frame(p, offset: 0).sig), .first)
        // Jumping more than the frame height leaves no overlap to match.
        XCTAssertEqual(stitcher.add(frame(p, offset: 1000).sig), .skip)
        XCTAssertEqual(stitcher.mismatchStreak, 1)
        // Coming back within range continues seamlessly.
        XCTAssertEqual(stitcher.add(frame(p, offset: 50).sig), .append(from: frameRows - 50, count: 50))
        XCTAssertEqual(stitcher.mismatchStreak, 0)
    }

    func testIdenticalFramesAreSkipped() {
        let p = page(rows: 1000, seed: 7)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(frame(p, offset: 10).sig)
        XCTAssertEqual(stitcher.add(frame(p, offset: 10).sig), .skip)
        XCTAssertEqual(stitcher.totalHeight, frameRows)
    }

    func testOffsetMatcherFindsExactShiftWithNoise() {
        let p = page(rows: 1200, seed: 8)
        let a = frame(p, offset: 100).sig
        var b = frame(p, offset: 173).sig
        // Mild noise (anti-aliasing, compression) must not throw the match off.
        for i in b.values.indices where i % 7 == 0 { b.values[i] += 1.5 }
        XCTAssertEqual(ScrollMatcher.offset(previous: a, current: b, top: 0, bottom: 0), 73)
    }
}
