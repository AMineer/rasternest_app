// Generates every RasterNest brand asset from one drawing of the mark.
//
//   swift scripts/generate-brand.swift
//
// Writes:
//   Resources/AppIcon.icns                     macOS app icon
//   site/assets/icon-512.png, favicon-64.png   website icons
//   site/assets/og.png                         1200×630 social preview
//   site/assets/logo-mark.svg                  vector mark (brackets use currentColor)
//   docs/assets/banner-light.png / -dark.png   README header (transparent)
//
// The mark: viewfinder brackets (capture) + 3×3 pixel grid (raster) + layered swoosh (nest).
import AppKit

// MARK: - Palette (keep in sync with docs/BRAND.md)

struct C {
    static let violet = rgb(0x7C3AED)
    static let violetLight = rgb(0xA78BFA)
    static let lavender = rgb(0xC4B5FD)
    static let sky = rgb(0x0EA5E9)
    static let highlight = rgb(0x38BDF8)
    static let ink = rgb(0x0B1020)
    static let slate = rgb(0x334155)
    static let white = rgb(0xFFFFFF)
    static let gridStart = rgb(0x8B5CF6)

    static func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
}

func hex(_ c: CGColor) -> String {
    let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
    return String(format: "#%02X%02X%02X", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
}

func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t,
                   blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
}

// MARK: - Mark geometry (1000 × 1000 unit space, y down)

enum Mark {
    static let bracketWidth: CGFloat = 56
    // Left bracket: down the side, round the corner, along the top.
    static let leftBracket: [CGPoint] = [CGPoint(x: 200, y: 330), CGPoint(x: 200, y: 175), CGPoint(x: 200, y: 120), CGPoint(x: 255, y: 120), CGPoint(x: 335, y: 120)]

    static let cell: CGFloat = 108, gap: CGFloat = 22, gridTop: CGFloat = 185
    static var gridLeft: CGFloat { 500 - (cell * 3 + gap * 2) / 2 }

    struct Band { let tipY: CGFloat; let inset: CGFloat; let topCtrl: CGFloat; let bottomCtrl: CGFloat; let from: CGColor; let to: CGColor }
    // Back to front: three ribbons that cradle the grid.
    static let bands: [Band] = [
        Band(tipY: 540, inset: 75, topCtrl: 830, bottomCtrl: 1010, from: C.violet, to: C.sky),
        Band(tipY: 485, inset: 35, topCtrl: 795, bottomCtrl: 975, from: C.violetLight, to: C.highlight),
        Band(tipY: 430, inset: 0, topCtrl: 760, bottomCtrl: 940, from: C.white, to: C.lavender),
    ]
    /// Vertical shift so the mark's visual centre sits at the centre of its box.
    static let centerShift: CGFloat = 50

    static func gridColor(col: Int, row: Int) -> CGColor {
        lerp(C.gridStart, C.highlight, CGFloat(col) / 2 * 0.8 + CGFloat(row) / 2 * 0.2)
    }

    /// Draws the mark into `rect` of a y-down context.
    /// `onLight` swaps the white front ribbon for lavender→sky so it reads on pale backgrounds.
    static func draw(in ctx: CGContext, rect: CGRect, brackets: CGColor, onLight: Bool = false) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 1000, y: rect.height / 1000)
        ctx.translateBy(x: 0, y: centerShift)

        // Nest bands (behind the grid's bottom row, in front of nothing else).
        for (i, b) in bands.enumerated() {
            let front = i == bands.count - 1
            let from = front && onLight ? C.lavender : b.from
            let to = front && onLight ? C.rgb(0x7DD3FC) : b.to
            let path = CGMutablePath()
            let l = CGPoint(x: 60 + b.inset, y: b.tipY), r = CGPoint(x: 940 - b.inset, y: b.tipY)
            path.move(to: l)
            path.addQuadCurve(to: r, control: CGPoint(x: 500, y: b.topCtrl))
            path.addQuadCurve(to: l, control: CGPoint(x: 500, y: b.bottomCtrl))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [from, to] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: l.x, y: 0), end: CGPoint(x: r.x, y: 0), options: [])
            ctx.restoreGState()
        }

        // Pixel grid.
        for row in 0..<3 {
            for col in 0..<3 {
                let r = CGRect(x: gridLeft + CGFloat(col) * (cell + gap), y: gridTop + CGFloat(row) * (cell + gap), width: cell, height: cell)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil))
                ctx.setFillColor(gridColor(col: col, row: row))
                ctx.fillPath()
            }
        }

        // Brackets.
        ctx.setStrokeColor(brackets)
        ctx.setLineWidth(bracketWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for mirror in [false, true] {
            let p = leftBracket.map { mirror ? CGPoint(x: 1000 - $0.x, y: $0.y) : $0 }
            ctx.move(to: p[0]); ctx.addLine(to: p[1])
            ctx.addQuadCurve(to: p[3], control: p[2])
            ctx.addLine(to: p[4])
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The same mark as SVG (brackets use currentColor so CSS can theme them).
    static func svg() -> String {
        var s = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 70 920 720" role="img" aria-label="RasterNest">"#
        s += "<defs>"
        for (i, b) in bands.enumerated() {
            s += #"<linearGradient id="rn-b\#(i)" x1="\#(60 + b.inset)" x2="\#(940 - b.inset)" y1="0" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="\#(i == bands.count - 1 ? "var(--rn-front-from, \(hex(b.from)))" : hex(b.from))"/><stop offset="1" stop-color="\#(i == bands.count - 1 ? "var(--rn-front-to, \(hex(b.to)))" : hex(b.to))"/></linearGradient>"#
        }
        s += "</defs>"
        for (i, b) in bands.enumerated() {
            let l = 60 + b.inset, r = 940 - b.inset
            s += #"<path fill="url(#rn-b\#(i))" d="M\#(l) \#(b.tipY) Q500 \#(b.topCtrl) \#(r) \#(b.tipY) Q500 \#(b.bottomCtrl) \#(l) \#(b.tipY)Z"/>"#
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let x = gridLeft + CGFloat(col) * (cell + gap), y = gridTop + CGFloat(row) * (cell + gap)
                s += #"<rect x="\#(x)" y="\#(y)" width="\#(cell)" height="\#(cell)" rx="18" fill="\#(hex(gridColor(col: col, row: row)))"/>"#
            }
        }
        for mirror in [false, true] {
            let p = leftBracket.map { mirror ? CGPoint(x: 1000 - $0.x, y: $0.y) : $0 }
            s += #"<path d="M\#(p[0].x) \#(p[0].y)L\#(p[1].x) \#(p[1].y)Q\#(p[2].x) \#(p[2].y) \#(p[3].x) \#(p[3].y)L\#(p[4].x) \#(p[4].y)" fill="none" stroke="currentColor" stroke-width="\#(bracketWidth)" stroke-linecap="round" stroke-linejoin="round"/>"#
        }
        return s + "</svg>\n"
    }
}

// MARK: - Canvas helper (y-down bitmap with AppKit text)

func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = ns.cgContext
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("✔ \(path)")
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, at p: CGPoint, tracking: CGFloat = 0) -> CGSize {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color)!,
        .kern: tracking,
    ]
    let str = s as NSString
    str.draw(at: p, withAttributes: attrs)
    return str.size(withAttributes: attrs)
}

func textSize(_ s: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat = 0) -> CGSize {
    (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .kern: tracking])
}

// MARK: - App icon

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(C.ink); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let base = CGGradient(colorsSpace: space, colors: [C.rgb(0x1C2147), C.ink] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    // Violet glow under the nest.
    let glow = CGGradient(colorsSpace: space, colors: [C.rgb(0x7C3AED, 0.55), C.rgb(0x7C3AED, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.maxY - 60 * s), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX, y: tile.maxY - 60 * s), endRadius: 520 * s, options: [])
    ctx.restoreGState()

    // Hairline highlight.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
    ctx.setStrokeColor(C.rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(3 * s); ctx.strokePath()

    let markSide = 640 * s
    Mark.draw(in: ctx, rect: CGRect(x: tile.midX - markSide / 2, y: tile.midY - markSide / 2 - 4 * s, width: markSide, height: markSide), brackets: C.white)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(width: px, height: px) { drawIcon($0, size: CGFloat(px)) }
            .representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "✔ Resources/AppIcon.icns" : "✘ iconutil failed")

writePNG(render(width: 512, height: 512) { drawIcon($0, size: 512) }, "site/assets/icon-512.png")
writePNG(render(width: 180, height: 180) { drawIcon($0, size: 180) }, "site/assets/apple-touch-icon.png")
writePNG(render(width: 64, height: 64) { drawIcon($0, size: 64) }, "site/assets/favicon-64.png")

// MARK: - Social preview

func drawHeroBackground(_ ctx: CGContext, _ r: CGRect) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let g = CGGradient(colorsSpace: space, colors: [C.rgb(0x2A1466), C.rgb(0x111735), C.ink] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
    // Soft violet waves.
    for (i, a) in [(0, 0.35), (1, 0.18)] as [(Int, CGFloat)] {
        let path = CGMutablePath()
        let y0 = r.maxY - r.height * (0.18 + 0.1 * CGFloat(i))
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: y0))
        path.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - r.height * (0.45 + 0.08 * CGFloat(i))),
                      control1: CGPoint(x: r.width * 0.35, y: y0 + r.height * 0.15),
                      control2: CGPoint(x: r.width * 0.65, y: r.maxY - r.height * 0.7))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(C.rgb(0x7C3AED, a))
        ctx.fillPath()
    }
}

writePNG(render(width: 1200, height: 630) { ctx in
    let r = CGRect(x: 0, y: 0, width: 1200, height: 630)
    drawHeroBackground(ctx, r)
    Mark.draw(in: ctx, rect: CGRect(x: 90, y: 150, width: 330, height: 330), brackets: C.white)
    ctx.setFillColor(C.rgb(0xFFFFFF, 0.25)); ctx.fill(CGRect(x: 470, y: 205, width: 2, height: 220))
    _ = text("RasterNest", size: 112, weight: .bold, color: C.white, at: CGPoint(x: 515, y: 190), tracking: -2)
    _ = text("Capture. Refine. Share.", size: 46, weight: .regular, color: C.rgb(0xFFFFFF, 0.78), at: CGPoint(x: 520, y: 340))
}, "site/assets/og.png")

// MARK: - README banners (transparent)

for (name, ink, sub) in [("light", C.ink, C.slate), ("dark", C.white, C.rgb(0xCBD5E1))] {
    writePNG(render(width: 1600, height: 400) { ctx in
        let title = "RasterNest", tagline = "Capture. Refine. Share."
        let tSize = textSize(title, size: 150, weight: .bold, tracking: -3)
        let markSide: CGFloat = 300
        let total = markSide + 60 + tSize.width
        let x0 = (1600 - total) / 2
        Mark.draw(in: ctx, rect: CGRect(x: x0, y: 50, width: markSide, height: markSide), brackets: ink, onLight: name == "light")
        _ = text(title, size: 150, weight: .bold, color: ink, at: CGPoint(x: x0 + markSide + 60, y: 70), tracking: -3)
        _ = text(tagline, size: 58, weight: .regular, color: sub, at: CGPoint(x: x0 + markSide + 66, y: 250))
    }, "docs/assets/banner-\(name).png")
}

// MARK: - SVG mark

try! Mark.svg().write(toFile: "site/assets/logo-mark.svg", atomically: true, encoding: .utf8)
print("✔ site/assets/logo-mark.svg")
