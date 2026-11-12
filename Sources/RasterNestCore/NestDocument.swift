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
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var imagePNG: Data
    /// Pixels per point of the original capture (2 for Retina).
    public var pixelScale: CGFloat
    public var annotations: [Annotation]
    public var createdAt: Date

    public init(imagePNG: Data, pixelScale: CGFloat, annotations: [Annotation], createdAt: Date = Date()) {
        self.formatVersion = Self.currentFormatVersion
        self.imagePNG = imagePNG
        self.pixelScale = pixelScale
        self.annotations = annotations
        self.createdAt = createdAt
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
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
