#if canImport(AppKit)
import CoreGraphics
import Foundation
import RasterNestCore

/// Draws several images into one using a `CombineLayout`.
public enum ImageCombiner {
    /// Longest side of the result; bigger layouts are scaled down to fit.
    public static let maxSide: CGFloat = 16_384

    /// - Parameters:
    ///   - images: images with their pixels-per-point scale. Mixed scales are matched to the highest.
    ///   - background: nil for transparent.
    /// - Returns: the combined image and its pixels-per-point scale.
    public static func combine(_ images: [(CGImage, CGFloat)], layout: CombineLayout,
                               background: RGBA? = RGBA(1, 1, 1)) -> (CGImage, CGFloat)? {
        guard !images.isEmpty else { return nil }
        let scale = images.map(\.1).max() ?? 1
        // Bring every image to the same density so a 1x and a 2x capture line up.
        let sizes = images.map { img, s in
            CGSize(width: CGFloat(img.width) * scale / max(s, 1), height: CGFloat(img.height) * scale / max(s, 1))
        }
        var placed = layout.place(sizes)
        let longest = max(placed.canvas.width, placed.canvas.height)
        if longest > maxSide {
            let f = maxSide / longest
            placed.canvas = CGSize(width: (placed.canvas.width * f).rounded(), height: (placed.canvas.height * f).rounded())
            placed.frames = placed.frames.map {
                CGRect(x: $0.minX * f, y: $0.minY * f, width: $0.width * f, height: $0.height * f).integral
            }
        }
        let w = Int(placed.canvas.width), h = Int(placed.canvas.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.interpolationQuality = .high
        for ((image, _), frame) in zip(images, placed.frames) {
            // Layout frames are top-left origin; CoreGraphics is bottom-left.
            let flipped = CGRect(x: frame.minX, y: CGFloat(h) - frame.maxY, width: frame.width, height: frame.height)
            ctx.draw(image, in: flipped)
        }
        guard let out = ctx.makeImage() else { return nil }
        return (out, scale)
    }
}
#endif
