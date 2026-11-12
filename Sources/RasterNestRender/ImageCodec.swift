#if canImport(AppKit)
import AppKit
import ImageIO
import RasterNestCore
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpg

    public var utType: UTType { self == .png ? .png : .jpeg }

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpg
        default: return nil
        }
    }
}

/// Reading and writing images and `.rasternest` documents.
public enum ImageCodec {
    public static func encode(_ image: CGImage, format: ExportFormat, scale: CGFloat, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        var output = image
        if format == .jpg {
            props[kCGImageDestinationLossyCompressionQuality] = quality
            output = flattenOnWhite(image) ?? image
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Decodes image data, inferring the pixel scale from its DPI (144 dpi → 2x).
    public static func decode(_ data: Data) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(1, (dpi / 72 * 2).rounded() / 2)
        return (image, CGFloat(scale))
    }

    public static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public static func loadDocument(_ url: URL) throws -> (NestDocument, CGImage) {
        let doc = try NestDocument.decoded(from: Data(contentsOf: url))
        guard let (image, _) = decode(doc.imagePNG) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (doc, image)
    }

    public static func makeDocument(image: CGImage, scale: CGFloat, annotations: [Annotation],
                                    effects: CanvasEffects? = nil) -> NestDocument? {
        guard let png = encode(image, format: .png, scale: scale) else { return nil }
        return NestDocument(imagePNG: png, pixelScale: scale, annotations: annotations, effects: effects)
    }

    public static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
#endif
