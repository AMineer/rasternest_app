#if canImport(AppKit)
import AppKit
import CoreGraphics

/// Writes one or more captures into a PDF, one per page.
public enum PDFComposer {
    public enum PageSize: String, CaseIterable, Sendable {
        /// Each page is exactly the size of its image (in points).
        case fit
        case letter
        case a4

        var size: CGSize? {
            switch self {
            case .fit: return nil
            case .letter: return CGSize(width: 612, height: 792)
            case .a4: return CGSize(width: 595.28, height: 841.89)
            }
        }
    }

    public struct Page {
        public var image: CGImage
        /// Pixels per point (2 for Retina) so pages come out at the on-screen size.
        public var scale: CGFloat
        public var caption: String?

        public init(image: CGImage, scale: CGFloat, caption: String? = nil) {
            self.image = image
            self.scale = scale
            self.caption = caption
        }
    }

    public enum Failure: LocalizedError {
        case noPages, cannotCreate
        public var errorDescription: String? {
            switch self {
            case .noPages: return "There's nothing to put in the PDF."
            case .cannotCreate: return "Couldn't create the PDF file."
            }
        }
    }

    public static func write(_ pages: [Page], to url: URL, pageSize: PageSize = .fit,
                             margin: CGFloat = 36, title: String? = nil) throws {
        guard !pages.isEmpty else { throw Failure.noPages }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [kCGPDFContextCreator: "RasterNest"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw Failure.cannotCreate }

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.2, green: 0.255, blue: 0.333, alpha: 1),
        ]

        for page in pages {
            let imageSize = CGSize(width: CGFloat(page.image.width) / page.scale,
                                   height: CGFloat(page.image.height) / page.scale)
            let captionHeight: CGFloat = page.caption == nil ? 0 : 24
            var media: CGRect
            var imageRect: CGRect
            if let fixed = pageSize.size {
                media = CGRect(origin: .zero, size: fixed)
                let avail = CGSize(width: fixed.width - margin * 2, height: fixed.height - margin * 2 - captionHeight)
                let k = min(1, avail.width / imageSize.width, avail.height / imageSize.height)
                let w = imageSize.width * k, h = imageSize.height * k
                // Top-aligned, horizontally centred (PDF origin is bottom-left).
                imageRect = CGRect(x: (fixed.width - w) / 2, y: fixed.height - margin - h, width: w, height: h)
            } else {
                let pad: CGFloat = page.caption == nil ? 0 : 16
                media = CGRect(x: 0, y: 0, width: imageSize.width + pad * 2, height: imageSize.height + captionHeight + pad * 2)
                imageRect = CGRect(x: pad, y: pad + captionHeight, width: imageSize.width, height: imageSize.height)
            }

            ctx.beginPDFPage([kCGPDFContextMediaBox: NSValue(rect: media)] as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(page.image, in: imageRect)
            if let caption = page.caption {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                (caption as NSString).draw(at: CGPoint(x: imageRect.minX, y: imageRect.minY - 18), withAttributes: captionAttrs)
                NSGraphicsContext.restoreGraphicsState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
#endif
