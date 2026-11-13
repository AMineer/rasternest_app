import Foundation
import RasterNestCore
#if canImport(Vision)
import ImageIO
import Vision
#endif

/// OCR: Apple Vision on macOS, `tesseract` on Linux.
public enum TextRecognition {
    public static func recognize(imageData: Data) async throws -> String {
        try await analyze(imageData: imageData).text
    }

    /// Recognized lines and words with their positions in image pixels (origin top-left).
    public static func analyze(imageData: Data) async throws -> OCRResult {
        #if canImport(Vision)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureFailure.backendFailed("Could not read the image.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let lines = try await analyze(cgImage: image)
        return OCRResult(width: image.width, height: image.height, scale: max(1, (dpi / 72 * 2).rounded() / 2), lines: lines)
        #else
        guard Shell.which("tesseract") != nil else {
            throw CaptureFailure.noBackend("Install `tesseract` (e.g. `sudo apt install tesseract-ocr`) for text recognition.")
        }
        guard let info = PNGInfo(imageData) else {
            throw CaptureFailure.backendFailed("Only PNG images are supported here.")
        }
        let tmp = Shell.temporaryPNG()
        try imageData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = try Shell.run("tesseract", [tmp.path, "stdout", "tsv"])
        guard result.status == 0 else { throw CaptureFailure.backendFailed("tesseract failed: \(result.stderr)") }
        return OCRResult(width: info.width, height: info.height, scale: info.scale,
                         lines: parseTesseractTSV(result.stdoutString))
        #endif
    }

    /// Groups tesseract's word rows (level 5) into lines by block, paragraph and line number.
    public static func parseTesseractTSV(_ tsv: String) -> [TextLine] {
        var order: [String] = []
        var grouped: [String: [(TextWord, Double)]] = [:]
        for row in tsv.split(separator: "\n").dropFirst() {
            let c = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 12, c[0] == "5" else { continue }
            let text = c[11...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let l = Double(c[6]), let t = Double(c[7]), let w = Double(c[8]), let h = Double(c[9]) else { continue }
            let conf = Double(c[10]) ?? 0
            let key = "\(c[1])-\(c[2])-\(c[3])-\(c[4])"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append((TextWord(text: text, box: PixelBox(x: l, y: t, width: w, height: h)), conf))
        }
        return order.compactMap { key in
            guard let words = grouped[key], let box = PixelBox.union(words.map(\.0.box)) else { return nil }
            let conf = words.map(\.1).reduce(0, +) / Double(words.count) / 100
            return TextLine(text: words.map(\.0.text).joined(separator: " "), confidence: max(0, min(1, conf)),
                            box: box, words: words.map(\.0))
        }
    }

    #if canImport(Vision)
    public static func recognize(cgImage: CGImage) async throws -> String {
        try await analyze(cgImage: cgImage).map(\.text).joined(separator: "\n")
    }

    public static func analyze(cgImage: CGImage) async throws -> [TextLine] {
        let w = Double(cgImage.width), h = Double(cgImage.height)
        func pixels(_ r: CGRect) -> PixelBox {
            // Vision: normalized, origin bottom-left.
            PixelBox(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    let lines: [TextLine] = (request.results ?? []).compactMap { obs in
                        guard let cand = obs.topCandidates(1).first else { return nil }
                        let s = cand.string
                        var words: [TextWord] = []
                        var idx = s.startIndex
                        while idx < s.endIndex {
                            guard let start = s[idx...].firstIndex(where: { !$0.isWhitespace }) else { break }
                            let end = s[start...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
                            if let b = try? cand.boundingBox(for: start..<end)?.boundingBox {
                                words.append(TextWord(text: String(s[start..<end]), box: pixels(b)))
                            }
                            idx = end
                        }
                        return TextLine(text: s, confidence: Double(cand.confidence), box: pixels(obs.boundingBox), words: words)
                    }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif
}
