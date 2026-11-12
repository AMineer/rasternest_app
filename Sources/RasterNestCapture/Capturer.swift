import Foundation

public enum CaptureTarget: Equatable, Sendable {
    /// Let the user pick an area or a window with the platform's selection UI.
    case interactive
    /// Let the user drag out an area.
    case interactiveRegion
    /// Let the user click a window.
    case interactiveWindow
    /// A whole display (index from `displays()`); nil = main display.
    case fullScreen(display: Int?)
    /// A rectangle in global points, origin at the top-left of the main display.
    case rect(CGRect)
    /// A window id from `windows()`.
    case window(UInt32)
}

public struct CaptureResult: Sendable {
    public var png: Data
    /// Image pixels per point (2 on Retina displays, usually 1 on Linux).
    public var pixelScale: Double

    public init(png: Data, pixelScale: Double) {
        self.png = png
        self.pixelScale = pixelScale
    }
}

public struct DisplayDescriptor: Codable, Sendable {
    public var index: Int
    public var id: UInt32
    public var name: String
    public var x: Double, y: Double, width: Double, height: Double
    public var scale: Double
    public var isMain: Bool
}

public struct WindowDescriptor: Codable, Sendable {
    public var id: UInt32
    public var owner: String
    public var title: String
    public var x: Double, y: Double, width: Double, height: Double
}

public enum CaptureFailure: LocalizedError, Equatable {
    case cancelled
    case permissionDenied(String)
    case unsupported(String)
    case noBackend(String)
    case backendFailed(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Capture cancelled."
        case .permissionDenied(let m), .unsupported(let m), .noBackend(let m),
             .backendFailed(let m), .notFound(let m): return m
        }
    }
}

/// One screen-capture implementation (ScreenCaptureKit on macOS, a CLI tool on Linux).
public protocol ScreenCapturer {
    var name: String { get }
    func displays() async throws -> [DisplayDescriptor]
    func windows() async throws -> [WindowDescriptor]
    func capture(_ target: CaptureTarget) async throws -> CaptureResult
}

public enum Capturers {
    /// The best capturer for this OS. `backend` forces a specific Linux tool.
    public static func make(backend: String? = nil) throws -> ScreenCapturer {
        #if canImport(ScreenCaptureKit)
        if let backend, backend != MacScreenCapturer.backendName {
            throw CaptureFailure.noBackend("Only the `\(MacScreenCapturer.backendName)` backend exists on macOS.")
        }
        return MacScreenCapturer()
        #elseif os(Linux)
        return try LinuxScreenCapturer(preferred: backend)
        #else
        throw CaptureFailure.unsupported("Screen capture is not implemented on this platform yet.")
        #endif
    }

    /// Backends usable on this machine, best first.
    public static func availableBackends() -> [String] {
        #if canImport(ScreenCaptureKit)
        return [MacScreenCapturer.backendName]
        #elseif os(Linux)
        return LinuxScreenCapturer.detectedBackends().map(\.rawValue)
        #else
        return []
        #endif
    }
}
