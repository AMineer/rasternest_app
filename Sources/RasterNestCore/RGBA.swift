import Foundation

/// A platform-neutral sRGB color with components in 0...1.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// Relative luminance (approximate, sRGB weights).
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// True when dark text reads better than white text on top of this color.
    public var prefersDarkText: Bool { luminance > 0.6 }

    public static let red = RGBA(0.94, 0.23, 0.20)
    public static let orange = RGBA(0.98, 0.55, 0.12)
    public static let yellow = RGBA(1.0, 0.86, 0.10)
    public static let green = RGBA(0.20, 0.72, 0.35)
    public static let blue = RGBA(0.16, 0.47, 0.96)
    public static let purple = RGBA(0.58, 0.32, 0.90)
    public static let black = RGBA(0.08, 0.08, 0.09)
    public static let white = RGBA(1, 1, 1)

    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}
