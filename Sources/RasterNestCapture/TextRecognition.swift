import Foundation
#if canImport(Vision)
import ImageIO
import Vision
#endif

/// OCR: Apple Vision on macOS, `tesseract` on Linux.
public enum TextRecognition {
    public static func recognize(imageData: Data) async throws -> String {
        #if canImport(Vision)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureFailure.backendFailed("Could not read the image.")
        }
        return try await recognize(cgImage: image)
        #else
        guard Shell.which("tesseract") != nil else {
            throw CaptureFailure.noBackend("Install `tesseract` (e.g. `sudo apt install tesseract-ocr`) for text recognition.")
        }
        let tmp = Shell.temporaryPNG()
        try imageData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = try Shell.run("tesseract", [tmp.path, "stdout"])
        guard result.status == 0 else { throw CaptureFailure.backendFailed("tesseract failed: \(result.stderr)") }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    #if canImport(Vision)
    public static func recognize(cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif
}
