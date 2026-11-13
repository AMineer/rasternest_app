import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A box in image pixels, origin top-left, y down. Codable as plain numbers so the
/// JSON is easy to read for scripts and AI agents.
public struct PixelBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ r: CGRect) { self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)) }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Whole pixels are plenty for placing markup and keep the JSON readable.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x.rounded(), forKey: .x)
        try c.encode(y.rounded(), forKey: .y)
        try c.encode(width.rounded(), forKey: .width)
        try c.encode(height.rounded(), forKey: .height)
    }

    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    public static func union(_ boxes: [PixelBox]) -> PixelBox? {
        guard var r = boxes.first?.rect else { return nil }
        for b in boxes.dropFirst() { r = r.union(b.rect) }
        return PixelBox(r)
    }
}

/// One recognized word.
public struct TextWord: Codable, Equatable, Sendable {
    public var text: String
    public var box: PixelBox
    public init(text: String, box: PixelBox) { self.text = text; self.box = box }
}

/// One recognized line of text with its words.
public struct TextLine: Codable, Equatable, Sendable {
    public var text: String
    /// 0…1 (Vision) or tesseract's 0…100 scaled to 0…1.
    public var confidence: Double
    public var box: PixelBox
    public var words: [TextWord]

    enum CodingKeys: String, CodingKey { case text, confidence, box, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        box = try c.decode(PixelBox.self, forKey: .box)
        words = try c.decodeIfPresent([TextWord].self, forKey: .words) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode((confidence * 100).rounded() / 100, forKey: .confidence)
        try c.encode(box, forKey: .box)
        if !words.isEmpty { try c.encode(words, forKey: .words) }
    }

    public init(text: String, confidence: Double, box: PixelBox, words: [TextWord]) {
        self.text = text; self.confidence = confidence; self.box = box; self.words = words
    }
}

/// Everything `rnest ocr --json` prints.
public struct OCRResult: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Image pixels per screen point (2 for Retina captures).
    public var scale: Double
    public var lines: [TextLine]

    public init(width: Int, height: Int, scale: Double, lines: [TextLine]) {
        self.width = width; self.height = height; self.scale = scale; self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// Finds text on an image: phrases for annotation anchors, patterns for redaction.
public enum TextMatcher {
    /// The box of the `occurrence`-th (1-based) place `phrase` appears, matched case-insensitively.
    /// Exact whole-line matches win over matches inside a longer line, so "Save" prefers the
    /// "Save" button over "Save As…" or a sentence that mentions saving.
    public static func find(_ phrase: String, in lines: [TextLine], occurrence: Int = 1) -> PixelBox? {
        let all = matches(of: phrase, in: lines)
        let index = max(1, occurrence) - 1
        return all.indices.contains(index) ? all[index] : nil
    }

    /// Every place `phrase` appears, best matches first, then top-to-bottom, left-to-right.
    public static func matches(of phrase: String, in lines: [TextLine]) -> [PixelBox] {
        let needle = normalize(phrase)
        guard !needle.isEmpty else { return [] }
        var exact: [PixelBox] = [], wordExact: [PixelBox] = [], partial: [PixelBox] = []
        for line in readingOrder(lines) {
            if normalize(line.text) == needle { exact.append(line.box); continue }
            // A run of whole words that spells the phrase.
            let words = line.words.map { normalize($0.text) }
            let target = needle.split(separator: " ").map(String.init)
            var found = false
            if !target.isEmpty && words.count >= target.count {
                for i in 0...(words.count - target.count) where Array(words[i..<(i + target.count)]) == target {
                    if let box = PixelBox.union(line.words[i..<(i + target.count)].map(\.box)) { wordExact.append(box) }
                    found = true
                }
            }
            if found { continue }
            if normalize(line.text).contains(needle) {
                // Narrow to the words that overlap the match where possible.
                let boxes = boxesCovering(needle, in: line)
                partial.append(boxes ?? line.box)
            }
        }
        return exact + wordExact + partial
    }

    /// Boxes of every match of a regular expression, one box per match (covering the words it touches).
    public static func boxes(matching regex: NSRegularExpression, in lines: [TextLine]) -> [PixelBox] {
        var out: [PixelBox] = []
        for line in readingOrder(lines) {
            let (joined, ranges) = joinedWords(line)
            let ns = joined as NSString
            for m in regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                let touched = zip(line.words, ranges).filter { NSIntersectionRange($0.1, m.range).length > 0 }.map(\.0.box)
                if let box = PixelBox.union(touched) { out.append(box) } else if line.words.isEmpty { out.append(line.box) }
            }
        }
        return out
    }

    // MARK: helpers

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "…", with: "...")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // Bullets, icons OCR'd as symbols, trailing colons and ellipses don't count.
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func readingOrder(_ lines: [TextLine]) -> [TextLine] {
        lines.sorted { a, b in
            // Same visual row if their vertical centers are within half a line height.
            let tolerance = min(a.box.height, b.box.height) / 2
            if abs(a.box.center.y - b.box.center.y) > tolerance { return a.box.center.y < b.box.center.y }
            return a.box.x < b.box.x
        }
    }

    /// The line's words joined by single spaces, plus each word's range in that string.
    static func joinedWords(_ line: TextLine) -> (String, [NSRange]) {
        guard !line.words.isEmpty else { return (line.text, []) }
        var s = "", ranges: [NSRange] = []
        for w in line.words {
            if !s.isEmpty { s += " " }
            let start = (s as NSString).length
            s += w.text
            ranges.append(NSRange(location: start, length: (w.text as NSString).length))
        }
        return (s, ranges)
    }

    private static func boxesCovering(_ needle: String, in line: TextLine) -> PixelBox? {
        let (joined, ranges) = joinedWords(line)
        let lower = joined.lowercased() as NSString
        let r = lower.range(of: needle)
        guard r.location != NSNotFound else { return nil }
        return PixelBox.union(zip(line.words, ranges).filter { NSIntersectionRange($0.1, r).length > 0 }.map(\.0.box))
    }
}

/// Built-in patterns for `redact` annotations.
public enum RedactionPattern: String, CaseIterable, Sendable {
    case email, phone, ipv4, url, card, token

    public var regex: NSRegularExpression {
        let pattern: String
        switch self {
        case .email: pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        case .phone: pattern = #"(?:\+?\d{1,3}[\s.\-]?)?(?:\(\d{3}\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4}"#
        case .ipv4: pattern = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        case .url: pattern = #"https?://\S+"#
        case .card: pattern = #"\b(?:\d[ \-]?){13,19}\b"#
        // Long opaque strings: API keys, tokens, hashes.
        case .token: pattern = #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#
        }
        return try! NSRegularExpression(pattern: pattern)
    }
}
