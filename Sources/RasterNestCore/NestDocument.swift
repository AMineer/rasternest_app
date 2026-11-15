import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum NestDocumentError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Editable capture: the original image plus its annotations (the `.rasternest` file format).
///
/// The format is plain JSON with the PNG embedded as base64 so other clients
/// (e.g. a future Windows app) can read and write it without any Apple frameworks.
public struct NestDocument: Codable, Sendable {
    public static let fileExtension = "rasternest"
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var imagePNG: Data
    /// Pixels per point of the original capture (2 for Retina).
    public var pixelScale: CGFloat
    public var annotations: [Annotation]
    /// Frame around the capture (padding, background, shadow…). Absent in files from 0.3 and earlier.
    public var effects: CanvasEffects?
    public var createdAt: Date

    public init(imagePNG: Data, pixelScale: CGFloat, annotations: [Annotation], effects: CanvasEffects? = nil,
                createdAt: Date = Date()) {
        self.effects = effects
        self.formatVersion = 1
        self.imagePNG = imagePNG
        self.pixelScale = pixelScale
        self.annotations = annotations
        self.createdAt = createdAt
    }

    /// Version 2 adds image layers. Files without them stay version 1 so older apps still open them;
    /// files with them are marked 2 so older apps say "needs a newer version" instead of failing oddly.
    public func encoded() throws -> Data {
        var copy = self
        if formatVersion <= Self.currentFormatVersion {
            copy.formatVersion = annotations.contains { $0.kind == .image } ? 2 : 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    public static func decoded(from data: Data) throws -> NestDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(NestDocument.self, from: data)
        guard doc.formatVersion <= currentFormatVersion else {
            throw NestDocumentError.unsupportedVersion(doc.formatVersion)
        }
        return doc
    }
}
