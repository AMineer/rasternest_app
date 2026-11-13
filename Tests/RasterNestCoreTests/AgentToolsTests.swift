import Foundation
import XCTest
@testable import RasterNestCapture
@testable import RasterNestCore

final class AgentToolsTests: XCTestCase {
    private func line(_ text: String, x: Double, y: Double, wordWidth: Double = 40) -> TextLine {
        var words: [TextWord] = []
        var cx = x
        for w in text.split(separator: " ") {
            words.append(TextWord(text: String(w), box: PixelBox(x: cx, y: y, width: wordWidth, height: 20)))
            cx += wordWidth + 10
        }
        let box = PixelBox.union(words.map(\.box))!
        return TextLine(text: text, confidence: 1, box: box, words: words)
    }

    private lazy var screen: [TextLine] = [
        line("Save As…", x: 10, y: 10),
        line("Cancel Save", x: 300, y: 400),
        line("• Save", x: 500, y: 600),
        line("Contact: jane.doe@example.com today", x: 20, y: 700),
    ]

    func testExactLineBeatsPartialMatches() {
        let box = TextMatcher.find("Save", in: screen)
        XCTAssertEqual(box?.x, 500) // "• Save" normalizes to "save"
        let all = TextMatcher.matches(of: "save", in: screen)
        XCTAssertEqual(all.count, 3)
        // Then whole-word matches in reading order: "Save" in "Save As…", then in "Cancel Save".
        XCTAssertEqual(all[1].x, 10)
        XCTAssertEqual(all[1].width, 40)
        XCTAssertEqual(TextMatcher.find("Save", in: screen, occurrence: 3)?.x, 350)
        XCTAssertNil(TextMatcher.find("Delete", in: screen))
    }

    func testRedactionCoversOnlyMatchingWords() {
        let boxes = TextMatcher.boxes(matching: RedactionPattern.email.regex, in: screen)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].x, 70) // second word
        XCTAssertEqual(boxes[0].width, 40)
    }

    func testSpecResolvesStepsArrowsAndRedaction() throws {
        let spec = AnnotationSpec(frame: "docs", annotations: [
            .init(type: "step", at: .init(text: "Cancel Save")),
            .init(type: "step", at: .init(x: 50, y: 60)),
            .init(type: "arrow", to: .init(text: "Save")),
            .init(type: "box", around: .init(rect: [1, 2, 30, 40])),
            .init(type: "redact", pattern: "email"),
        ])
        XCTAssertTrue(spec.needsOCR)
        let anns = try spec.resolve(imageSize: CGSize(width: 1000, height: 800), scale: 2, lines: screen)
        XCTAssertEqual(anns.map(\.kind), [.step, .step, .arrow, .rectangle, .pixelate])
        XCTAssertEqual(anns[0].number, 1)
        XCTAssertEqual(anns[1].number, 2)
        XCTAssertLessThan(anns[0].start.x, 300) // left of the text
        XCTAssertEqual(anns[1].start, CGPoint(x: 50, y: 60))
        XCTAssertEqual(anns[3].rect, CGRect(x: 1, y: 2, width: 30, height: 40))
        // Arrow ends on the edge of the "• Save" box, not in its middle.
        let end = anns[2].end
        // Target box is padded by 4pt (8px at 2x).
        XCTAssertTrue(CGRect(x: 492, y: 592, width: 106, height: 36).insetBy(dx: -1, dy: -1).contains(end))
        XCTAssertFalse(CGRect(x: 500, y: 600, width: 90, height: 20).insetBy(dx: 1, dy: 1).contains(end))
        XCTAssertNotNil(try spec.effects(scale: 2))
    }

    func testSpecErrorsAreHelpful() {
        let missing = AnnotationSpec(annotations: [.init(type: "step", at: .init(text: "Delete"))])
        XCTAssertThrowsError(try missing.resolve(imageSize: CGSize(width: 100, height: 100), scale: 1, lines: screen)) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("Delete"))
            XCTAssertTrue(text.contains("Cancel Save"))
        }
        let bad = AnnotationSpec(annotations: [.init(type: "sparkle", at: .init(x: 1, y: 1))])
        XCTAssertThrowsError(try bad.resolve(imageSize: CGSize(width: 10, height: 10), scale: 1, lines: []))
        XCTAssertEqual(try AnnotationSpec.parseColor("#7C3AED"), RGBA(124 / 255, 58 / 255, 237 / 255))
    }

    func testSpecDecodesFromJSON() throws {
        let json = #"{"annotations":[{"type":"step","at":{"text":"Save"},"label":"Click"},{"type":"redact","pattern":"email"}]}"#
        let spec = try JSONDecoder().decode(AnnotationSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.annotations.count, 2)
        XCTAssertEqual(spec.annotations[0].label, "Click")
    }

    func testPNGInfoReadsSizeAndDensity() throws {
        // 1×1 PNG with a pHYs chunk of 5669 px/m (144 dpi).
        let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAABYlAAAWJQFJUiTwAAAADUlEQVQImWP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        let info = try XCTUnwrap(PNGInfo(Data(base64Encoded: b64)!))
        XCTAssertEqual(info.width, 1)
        XCTAssertEqual(info.height, 1)
        XCTAssertEqual(info.scale, 2)
        XCTAssertNil(PNGInfo(Data("nope".utf8)))
    }

    func testGuideStemsAndMarkdown() throws {
        let guide = Guide(title: "T", steps: [
            .init(name: "Open Settings!", caption: "Open it.", capture: .init(fullscreen: true)),
            .init(capture: .init(file: "a.png")),
        ])
        XCTAssertEqual(guide.stem(for: 0), "01-open-settings")
        XCTAssertEqual(guide.stem(for: 1), "02")
        let md = guide.markdown(imagePaths: ["img/01-open-settings.png", "img/02.png"])
        XCTAssertTrue(md.hasPrefix("# T\n"))
        XCTAssertTrue(md.contains("![Open it.](img/01-open-settings.png)"))
        let roundTrip = try Guide.decoded(from: JSONEncoder().encode(Guide.example))
        XCTAssertEqual(roundTrip, Guide.example)
    }

    func testTesseractTSVGroupsWordsIntoLines() {
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        4\t1\t1\t1\t1\t0\t10\t10\t100\t20\t-1\t
        5\t1\t1\t1\t1\t1\t10\t10\t40\t20\t96\tSave
        5\t1\t1\t1\t1\t2\t60\t10\t50\t20\t90\tchanges
        5\t1\t1\t1\t2\t1\t10\t40\t60\t20\t80\tCancel
        """
        let lines = TextRecognition.parseTesseractTSV(tsv)
        XCTAssertEqual(lines.map(\.text), ["Save changes", "Cancel"])
        XCTAssertEqual(lines[0].box, PixelBox(x: 10, y: 10, width: 100, height: 20))
        XCTAssertEqual(lines[0].confidence, 0.93, accuracy: 0.001)
    }

    func testMCPServerProtocol() async throws {
        let echo = MCPTool(name: "echo", description: "Echo", inputSchema: ["type": "object"]) { args in
            guard let s = args["text"]?.string else { throw AnnotationSpec.ResolveError.badAnchor("no text") }
            return [.text(s)]
        }
        let server = MCPServer(name: "t", version: "1", tools: [echo])

        func call(_ s: String) async throws -> JSONValue {
            let response = await server.handle(line: s)
            let out = try XCTUnwrap(response)
            return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
        }

        let initResult = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(initResult["result"]?["protocolVersion"]?.string, "2025-06-18")
        let oldClient = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(oldClient["result"]?["protocolVersion"]?.string, MCPServer.supportedVersions[0])

        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)

        let list = try await call(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        XCTAssertEqual(list["id"]?.string, "a")
        XCTAssertEqual(list["result"]?["tools"]?.array?.first?["name"]?.string, "echo")

        let ok = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        XCTAssertEqual(ok["result"]?["content"]?.array?.first?["text"]?.string, "hi")
        XCTAssertEqual(ok["result"]?["isError"]?.bool, false)

        let toolError = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        XCTAssertEqual(toolError["result"]?["isError"]?.bool, true)

        let unknown = try await call(#"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)
        XCTAssertEqual(unknown["error"]?["code"]?.int, -32601)

        let parse = try await call("{not json")
        XCTAssertEqual(parse["error"]?["code"]?.int, -32700)
    }
}
