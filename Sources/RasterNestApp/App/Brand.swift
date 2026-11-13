import AppKit
import SwiftUI

/// RasterNest brand colors and marks (see docs/BRAND.md).
enum Brand {
    static let tagline = "Capture. Refine. Share."
    static let sponsorURL = URL(string: "https://rasternest.app/#support")!
    static func openSponsor() { NSWorkspace.shared.open(sponsorURL) }

    static let violet = NSColor(srgbRed: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255, alpha: 1)   // #7C3AED primary
    static let sky = NSColor(srgbRed: 0x0E / 255, green: 0xA5 / 255, blue: 0xE9 / 255, alpha: 1)      // #0EA5E9 accent
    static let highlight = NSColor(srgbRed: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255, alpha: 1) // #38BDF8
    static let ink = NSColor(srgbRed: 0x0B / 255, green: 0x10 / 255, blue: 0x20 / 255, alpha: 1)      // #0B1020

    static var violetColor: Color { Color(nsColor: violet) }

    /// Menu-bar glyph: the logo's capture brackets, pixel grid and nest, as a template image.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.set()
            // Brackets
            let brackets = NSBezierPath()
            brackets.lineWidth = 1.6
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            brackets.move(to: NSPoint(x: 3.2, y: 6.2)); brackets.line(to: NSPoint(x: 3.2, y: 2.2)); brackets.line(to: NSPoint(x: 6.4, y: 2.2))
            brackets.move(to: NSPoint(x: 16.8, y: 6.2)); brackets.line(to: NSPoint(x: 16.8, y: 2.2)); brackets.line(to: NSPoint(x: 13.6, y: 2.2))
            brackets.stroke()
            // 3×3 grid
            for row in 0..<3 {
                for col in 0..<3 {
                    NSBezierPath(roundedRect: NSRect(x: 6.6 + CGFloat(col) * 2.45, y: 3.6 + CGFloat(row) * 2.45, width: 1.9, height: 1.9),
                                 xRadius: 0.4, yRadius: 0.4).fill()
                }
            }
            // Nest swoosh
            let nest = NSBezierPath()
            nest.move(to: NSPoint(x: 1.5, y: 9.6))
            nest.curve(to: NSPoint(x: 18.5, y: 9.6), controlPoint1: NSPoint(x: 5.5, y: 15.6), controlPoint2: NSPoint(x: 14.5, y: 15.6))
            nest.curve(to: NSPoint(x: 1.5, y: 9.6), controlPoint1: NSPoint(x: 14.5, y: 13.4), controlPoint2: NSPoint(x: 5.5, y: 13.4))
            nest.close()
            nest.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RasterNest"
        return image
    }

    @MainActor
    static func showAbout() {
        ActivationPolicy.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(string: tagline + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: violet,
        ])
        credits.append(NSAttributedString(string: "Free and open source · rasternest.app", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
