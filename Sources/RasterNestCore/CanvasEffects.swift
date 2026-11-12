import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A frame around a capture: padding, background, rounded corners, drop shadow and border.
/// Sizes are in image pixels. Stored in `.rasternest` files (optional, so older files still open).
public struct CanvasEffects: Codable, Equatable, Sendable {
    public enum Background: String, Codable, CaseIterable, Sendable {
        case none, solid, gradient
    }

    public var padding: CGFloat
    public var background: Background
    public var backgroundColor: RGBA
    /// Second gradient color (top-left → bottom-right).
    public var backgroundColor2: RGBA
    public var cornerRadius: CGFloat
    public var shadow: Bool
    public var borderWidth: CGFloat
    public var borderColor: RGBA

    public init(padding: CGFloat = 0, background: Background = .none,
                backgroundColor: RGBA = RGBA(0.973, 0.980, 0.988), backgroundColor2: RGBA = RGBA(0.886, 0.910, 0.941),
                cornerRadius: CGFloat = 0, shadow: Bool = false,
                borderWidth: CGFloat = 0, borderColor: RGBA = RGBA(0.886, 0.910, 0.941)) {
        self.padding = padding
        self.background = background
        self.backgroundColor = backgroundColor
        self.backgroundColor2 = backgroundColor2
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.borderWidth = borderWidth
        self.borderColor = borderColor
    }

    public static let none = CanvasEffects()

    /// A clean "docs" look scaled for the image's pixel density.
    public static func documentation(scale: CGFloat) -> CanvasEffects {
        CanvasEffects(padding: 32 * scale, background: .gradient,
                      backgroundColor: RGBA(0.929, 0.914, 0.996), backgroundColor2: RGBA(0.878, 0.949, 0.996),
                      cornerRadius: 10 * scale, shadow: true, borderWidth: 0)
    }

    public var isEmpty: Bool { padding <= 0 && cornerRadius <= 0 && !shadow && borderWidth <= 0 }

    /// Size of the framed result for an image of `size`.
    public func outputSize(for size: CGSize) -> CGSize {
        CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
    }
}
