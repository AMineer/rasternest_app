#if canImport(AppKit)
import AppKit
import CoreImage
import RasterNestCore

public extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}

/// Text sizing shared by the renderer and the editor's inline text field.
public enum TextMetrics {
    public static func font(for a: Annotation) -> NSFont {
        .systemFont(ofSize: a.style.fontSize, weight: .semibold)
    }

    public static func padding(for a: Annotation) -> CGFloat {
        a.style.filled ? a.style.fontSize * 0.45 : 0
    }

    public static func textColor(for a: Annotation) -> NSColor {
        guard a.style.filled else { return a.style.color.nsColor }
        return a.style.color.prefersDarkText ? .black : .white
    }

    public static func attributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        [.font: font(for: a), .foregroundColor: textColor(for: a)]
    }

    public static func textSize(_ text: String, for a: Annotation) -> CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let r = s.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                               attributes: attributes(for: a))
        return CGSize(width: max(ceil(r.width), a.style.fontSize * 0.5), height: ceil(r.height))
    }

    /// Sets `end` so that `rect` wraps the text plus callout padding.
    public static func layout(_ a: inout Annotation) {
        let size = textSize(a.text, for: a)
        let p = padding(for: a)
        a.end = CGPoint(x: a.start.x + size.width + p * 2, y: a.start.y + size.height + p * 2)
    }
}

/// Draws a base image plus annotations into a y-down CGContext measured in image pixels.
///
/// Used for the editor canvas, clipboard/export flattening and `rnest export`.
public final class AnnotationRenderer {
    /// Pixel scale of the image (2 for Retina); sizes shadows and details consistently.
    public var unit: CGFloat = 1

    private var pixelateCache: [Int: CGImage] = [:]
    private var cacheSource: CGImage?
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    public init(unit: CGFloat = 1) { self.unit = unit }

    /// Draws `image` right side up inside a y-down context.
    public static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// Renders everything. The current NSGraphicsContext must wrap `ctx` with `flipped: true`.
    public func render(base: CGImage, annotations: [Annotation], in ctx: CGContext, textHiddenFor hiddenID: UUID? = nil) {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.saveGState()
        ctx.interpolationQuality = deviceScale(ctx) >= 1.99 ? .none : .high
        Self.drawImage(base, in: full, ctx)
        ctx.restoreGState()

        let spotlights = annotations.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty { drawSpotlights(spotlights, full: full, ctx) }

        for a in annotations where a.kind != .spotlight {
            draw(a, base: base, full: full, ctx: ctx, hideText: a.id == hiddenID)
        }
    }

    /// Produces a new image with the annotations burned in.
    public func flatten(image: CGImage, annotations: [Annotation]) -> CGImage? {
        let w = image.width, h = image.height
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(base: image, annotations: annotations, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - Drawing

    private func deviceScale(_ ctx: CGContext) -> CGFloat {
        let t = ctx.userSpaceToDeviceSpaceTransform
        return max((t.a * t.a + t.b * t.b).squareRoot(), 0.0001)
    }

    private func applyShadow(_ ctx: CGContext, _ a: Annotation) {
        guard a.style.shadow else { return }
        let k = deviceScale(ctx)
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * unit * k), blur: 4 * unit * k,
                      color: CGColor(gray: 0, alpha: 0.45))
    }

    private func draw(_ a: Annotation, base: CGImage, full: CGRect, ctx: CGContext, hideText: Bool) {
        let color = a.style.color.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch a.kind {
        case .arrow:
            applyShadow(ctx, a)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let head = Geometry.arrowHead(start: a.start, end: a.end, lineWidth: a.style.lineWidth)
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(a.style.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: head.base)
            ctx.strokePath()
            ctx.setLineJoin(.round)
            ctx.move(to: head.tip)
            ctx.addLine(to: head.left)
            ctx.addLine(to: head.right)
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()

        case .line:
            applyShadow(ctx, a)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.style.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()

        case .rectangle, .ellipse:
            applyShadow(ctx, a)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let r = a.rect
            let path = a.kind == .rectangle ? CGPath(rect: r, transform: nil) : CGPath(ellipseIn: r, transform: nil)
            if a.style.filled {
                ctx.addPath(path)
                ctx.setFillColor(a.style.color.withAlpha(0.25).cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.style.lineWidth)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.endTransparencyLayer()

        case .highlight:
            // Normal blending stays visible on dark-mode screenshots (multiply vanishes there).
            ctx.setFillColor(a.style.color.withAlpha(Double(a.style.opacity)).cgColor)
            ctx.fill(a.rect)

        case .pixelate:
            guard let pixelated = pixelated(base, block: a.style.lineWidth) else { return }
            ctx.clip(to: a.rect)
            Self.drawImage(pixelated, in: full, ctx)

        case .spotlight:
            break // drawn together in drawSpotlights

        case .pen:
            let pts = a.points
            guard pts.count > 1 else { return }
            applyShadow(ctx, a)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.style.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: pts[0])
            for i in 1..<pts.count {
                ctx.addQuadCurve(to: Geometry.midpoint(pts[i - 1], pts[i]), control: pts[i - 1])
            }
            ctx.addLine(to: pts[pts.count - 1])
            ctx.strokePath()

        case .step:
            drawStep(a, ctx)

        case .text:
            drawText(a, ctx, hideText: hideText)
        }
    }

    private func drawStep(_ a: Annotation, _ ctx: CGContext) {
        let r = a.stepRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        applyShadow(ctx, a)
        ctx.setFillColor(a.style.color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let ring = max(1.5 * unit, r * 0.1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(ring)
        ctx.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))

        let label = "\(a.number)" as NSString
        let fontSize = label.length > 1 ? r * 0.95 : r * 1.15
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: a.style.color.prefersDarkText ? NSColor.black : NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)
    }

    private func drawText(_ a: Annotation, _ ctx: CGContext, hideText: Bool) {
        let p = TextMetrics.padding(for: a)
        // Always measure: files from other clients (or older versions) may store a stale box.
        var laidOut = a
        TextMetrics.layout(&laidOut)
        let r = laidOut.rect
        applyShadow(ctx, a)
        if a.style.filled {
            let radius = min(a.style.fontSize * 0.35, r.height / 2, r.width / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(a.style.color.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        guard !hideText else { return }
        let box = CGRect(x: r.minX + p, y: r.minY + p,
                         width: max(r.width - p * 2, 1) + 2, height: max(r.height - p * 2, 1) + 2)
        (a.text as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: TextMetrics.attributes(for: a), context: nil)
    }

    private func drawSpotlights(_ spots: [Annotation], full: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let dim = spots.map(\.style.opacity).max() ?? 0.55
        ctx.setFillColor(CGColor(gray: 0, alpha: dim))
        ctx.fill(full)
        ctx.setBlendMode(.clear)
        for s in spots {
            let r = s.rect
            let radius = min(12 * unit, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func pixelated(_ base: CGImage, block: CGFloat) -> CGImage? {
        if cacheSource !== base {
            pixelateCache.removeAll()
            cacheSource = base
        }
        let key = max(2, Int(block.rounded()))
        if let cached = pixelateCache[key] { return cached }
        let input = CIImage(cgImage: base)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(CGFloat(key), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = Self.ciContext.createCGImage(output, from: input.extent) else { return nil }
        pixelateCache[key] = result
        return result
    }
}
#endif
