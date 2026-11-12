// Draws the RasterNest app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/generate-icon.swift [output.icns]
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle-ish background with a teal → indigo gradient.
    let inset = 100 * s
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.72, blue: 0.70, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.25, blue: 0.80, alpha: 1)])!
        .draw(in: tilePath, angle: -60)

    // Pixel grid ("raster") in the lower-left.
    let cell = 54 * s
    let gridOrigin = NSPoint(x: 230 * s, y: 230 * s)
    for row in 0..<4 {
        for col in 0..<4 where row + col < 4 {
            let alpha = 0.18 + 0.12 * CGFloat(3 - row - col)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: gridOrigin.x + CGFloat(col) * (cell + 10 * s),
                                             y: gridOrigin.y + CGFloat(row) * (cell + 10 * s),
                                             width: cell, height: cell),
                         xRadius: 8 * s, yRadius: 8 * s).fill()
        }
    }

    // Viewfinder corners.
    NSColor.white.setStroke()
    let corner = NSBezierPath()
    corner.lineWidth = 46 * s
    corner.lineCapStyle = .round
    corner.lineJoinStyle = .round
    let a: CGFloat = 250 * s, b: CGFloat = size - 250 * s, len: CGFloat = 150 * s
    for (x, y, dx, dy) in [(a, b, 1.0, -1.0), (b, b, -1.0, -1.0), (b, a, -1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        corner.move(to: NSPoint(x: x, y: y + dy * len))
        corner.line(to: NSPoint(x: x, y: y))
        corner.line(to: NSPoint(x: x + dx * len, y: y))
    }
    corner.stroke()

    // Annotation arrow in coral.
    let coral = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1)
    coral.setStroke()
    coral.setFill()
    let shaft = NSBezierPath()
    shaft.lineWidth = 52 * s
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: 420 * s, y: 420 * s))
    shaft.line(to: NSPoint(x: 650 * s, y: 650 * s))
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 760 * s, y: 760 * s))
    head.line(to: NSPoint(x: 560 * s, y: 715 * s))
    head.line(to: NSPoint(x: 715 * s, y: 560 * s))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 20 * s
    head.fill()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
