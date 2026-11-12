import XCTest
@testable import RasterNestCore

final class GeometryTests: XCTestCase {
    func testRectNormalizes() {
        let r = Geometry.rect(CGPoint(x: 10, y: 20), CGPoint(x: 2, y: 5))
        XCTAssertEqual(r, CGRect(x: 2, y: 5, width: 8, height: 15))
    }

    func testSegmentDistance() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        XCTAssertEqual(Geometry.distance(from: CGPoint(x: 5, y: 3), toSegment: a, b), 3, accuracy: 0.0001)
        XCTAssertEqual(Geometry.distance(from: CGPoint(x: -4, y: 3), toSegment: a, b), 5, accuracy: 0.0001)
    }

    func testArrowHeadSitsOnTheShaft() {
        let head = Geometry.arrowHead(start: .zero, end: CGPoint(x: 100, y: 0), lineWidth: 4)
        XCTAssertEqual(head.tip, CGPoint(x: 100, y: 0))
        XCTAssertLessThan(head.base.x, 100)
        XCTAssertEqual(head.base.y, 0, accuracy: 0.0001)
        XCTAssertEqual(head.left.y, -head.right.y, accuracy: 0.0001)
    }

    func testArrowHeadNeverLongerThanArrow() {
        let head = Geometry.arrowHead(start: .zero, end: CGPoint(x: 5, y: 0), lineWidth: 10)
        XCTAssertGreaterThanOrEqual(head.base.x, 0 - 0.0001)
    }

    func testSnapAngle() {
        let p = Geometry.snapAngle(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(p.y, 0, accuracy: 0.0001)
        let d = Geometry.snapAngle(from: .zero, to: CGPoint(x: 50, y: 47))
        XCTAssertEqual(d.x, d.y, accuracy: 0.0001)
    }

    func testSnapSquare() {
        let p = Geometry.snapSquare(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: 40))
        XCTAssertEqual(p, CGPoint(x: -20, y: 40))
    }
}

final class AnnotationTests: XCTestCase {
    func testArrowHitTest() {
        let a = Annotation(kind: .arrow, start: .zero, end: CGPoint(x: 100, y: 100))
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 52)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 80)))
    }

    func testHollowRectangleHitsOnlyEdges() {
        let a = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 100, y: 100))
        XCTAssertTrue(a.hitTest(CGPoint(x: 0, y: 50)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 50)))
        var filled = a
        filled.style.filled = true
        XCTAssertTrue(filled.hitTest(CGPoint(x: 50, y: 50)))
    }

    func testEllipseHitTest() {
        let a = Annotation(kind: .ellipse, start: .zero, end: CGPoint(x: 200, y: 100))
        XCTAssertTrue(a.hitTest(CGPoint(x: 200, y: 50)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 100, y: 50)))
        XCTAssertFalse(a.hitTest(CGPoint(x: 0, y: 0)))
    }

    func testMoveHandleCorners() {
        var a = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 10, y: 10))
        a.moveHandle(2, to: CGPoint(x: -5, y: 20))
        XCTAssertEqual(a.rect, CGRect(x: -5, y: 0, width: 15, height: 20))
        a.moveHandle(3, to: CGPoint(x: 30, y: -10))
        XCTAssertEqual(a.rect, CGRect(x: -5, y: -10, width: 35, height: 30))
    }

    func testTranslateMovesPenPoints() {
        var a = Annotation(kind: .pen, start: .zero, points: [.zero, CGPoint(x: 1, y: 1)])
        a.translate(dx: 5, dy: -2)
        XCTAssertEqual(a.points, [CGPoint(x: 5, y: -2), CGPoint(x: 6, y: -1)])
    }

    func testDegenerate() {
        XCTAssertTrue(Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 1, y: 2)).isDegenerate)
        XCTAssertFalse(Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 10, y: 2)).isDegenerate)
        XCTAssertFalse(Annotation(kind: .step, start: .zero).isDegenerate)
    }

    func testNextStepNumber() {
        let list = [
            Annotation(kind: .step, start: .zero, number: 1),
            Annotation(kind: .arrow, start: .zero),
            Annotation(kind: .step, start: .zero, number: 4),
        ]
        XCTAssertEqual(Annotation.nextStepNumber(in: list), 5)
        XCTAssertEqual(Annotation.nextStepNumber(in: []), 1)
    }
}

final class DocumentTests: XCTestCase {
    func testRoundTrip() throws {
        let annotations = [
            Annotation(kind: .text, start: CGPoint(x: 3, y: 4), text: "Hello", style: AnnotationStyle(color: .blue)),
            Annotation(kind: .step, start: CGPoint(x: 9, y: 9), number: 2),
        ]
        let doc = NestDocument(imagePNG: Data([1, 2, 3]), pixelScale: 2, annotations: annotations)
        let decoded = try NestDocument.decoded(from: doc.encoded())
        XCTAssertEqual(decoded.annotations, annotations)
        XCTAssertEqual(decoded.imagePNG, Data([1, 2, 3]))
        XCTAssertEqual(decoded.pixelScale, 2)
    }

    func testRejectsFutureVersions() throws {
        var doc = NestDocument(imagePNG: Data(), pixelScale: 1, annotations: [])
        doc.formatVersion = 99
        XCTAssertThrowsError(try NestDocument.decoded(from: doc.encoded())) { error in
            XCTAssertEqual(error as? NestDocumentError, .unsupportedVersion(99))
        }
    }
}

final class CanvasEffectsTests: XCTestCase {
    func testEffectsRoundTripInDocument() throws {
        let effects = CanvasEffects.documentation(scale: 2)
        let doc = NestDocument(imagePNG: Data([9]), pixelScale: 2, annotations: [], effects: effects)
        XCTAssertEqual(try NestDocument.decoded(from: doc.encoded()).effects, effects)
    }

    func testDocumentsWithoutEffectsStillDecode() throws {
        // Files written by 0.3 and earlier have no "effects" key.
        var json = try JSONSerialization.jsonObject(with: NestDocument(imagePNG: Data(), pixelScale: 1, annotations: []).encoded()) as! [String: Any]
        json.removeValue(forKey: "effects")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try NestDocument.decoded(from: data).effects)
    }

    func testOutputSizeAddsPaddingOnBothSides() {
        let e = CanvasEffects(padding: 30)
        XCTAssertEqual(e.outputSize(for: CGSize(width: 100, height: 50)), CGSize(width: 160, height: 110))
        XCTAssertTrue(CanvasEffects.none.isEmpty)
        XCTAssertFalse(e.isEmpty)
    }
}
