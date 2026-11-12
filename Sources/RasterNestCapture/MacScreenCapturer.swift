#if canImport(ScreenCaptureKit)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// ScreenCaptureKit-based capture. Used directly by the CLI, and by the app for its frozen-screen overlay.
public final class MacScreenCapturer: ScreenCapturer {
    public static let backendName = "screencapturekit"
    public var name: String { Self.backendName }

    public init() {}

    // MARK: ScreenCapturer

    public func displays() async throws -> [DisplayDescriptor] {
        Self.activeDisplayIDs().enumerated().map { index, id in
            let b = CGDisplayBounds(id)
            return DisplayDescriptor(index: index, id: id, name: "Display \(index)",
                                     x: b.minX, y: b.minY, width: b.width, height: b.height,
                                     scale: Self.scale(of: id), isMain: CGDisplayIsMain(id) != 0)
        }
    }

    public func windows() async throws -> [WindowDescriptor] {
        Self.onScreenWindows().map {
            WindowDescriptor(id: $0.id, owner: $0.owner, title: $0.title,
                             x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height)
        }
    }

    public func capture(_ target: CaptureTarget) async throws -> CaptureResult {
        await Self.ensureWindowServerConnection()
        switch target {
        case .interactive:
            return try systemInteractive(["-i"])
        case .interactiveRegion:
            return try systemInteractive(["-i", "-s"])
        case .interactiveWindow:
            return try systemInteractive(["-i", "-W"])
        case .fullScreen(let index):
            try Self.requirePermission()
            let ids = Self.activeDisplayIDs()
            let id: CGDirectDisplayID
            if let index {
                guard ids.indices.contains(index) else { throw CaptureFailure.notFound("No display \(index). Run `rnest displays`.") }
                id = ids[index]
            } else {
                id = CGMainDisplayID()
            }
            let (image, scale) = try await Self.snapshot(displayID: id)
            return try Self.result(image, scale: scale)
        case .rect(let rect):
            try Self.requirePermission()
            let ids = Self.activeDisplayIDs()
            // Use the display holding most of the rectangle.
            guard let id = ids.max(by: { area(CGDisplayBounds($0).intersection(rect)) < area(CGDisplayBounds($1).intersection(rect)) }),
                  !CGDisplayBounds(id).intersection(rect).isNull else {
                throw CaptureFailure.notFound("That rectangle is not on any display.")
            }
            let bounds = CGDisplayBounds(id)
            let local = rect.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let (image, scale) = try await Self.snapshot(displayID: id, sourceRect: local)
            return try Self.result(image, scale: scale)
        case .window(let id):
            try Self.requirePermission()
            let (image, scale) = try await Self.captureWindow(id: id)
            return try Self.result(image, scale: scale)
        }
    }

    // MARK: Building blocks shared with the app

    public struct WindowInfo: Sendable {
        public let id: CGWindowID
        /// Global coordinates, origin top-left of the main display, y down.
        public let frame: CGRect
        public let owner: String
        public let title: String
    }

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Command-line processes have no WindowServer connection until AppKit is initialised,
    /// and some ScreenCaptureKit calls (window filters) assert without one.
    public static func ensureWindowServerConnection() async {
        await MainActor.run { _ = NSApplication.shared }
    }

    public static func requirePermission() throws {
        guard hasPermission else {
            CGRequestScreenCaptureAccess()
            throw CaptureFailure.permissionDenied(
                "Screen Recording permission is required. Enable it for this app (or your terminal) in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
        }
    }

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    public static func scale(of id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// Grabs a display (or part of it, in display-local points) at native resolution.
    public static func snapshot(displayID: CGDirectDisplayID, sourceRect: CGRect? = nil) async throws -> (CGImage, Double) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.notFound("Display \(displayID) is not available.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = scale(of: displayID)
        let bounds = CGDisplayBounds(displayID)
        let area = sourceRect ?? CGRect(origin: .zero, size: bounds.size)
        let config = SCStreamConfiguration()
        if sourceRect != nil { config.sourceRect = area }
        config.width = max(1, Int((area.width * scale).rounded()))
        config.height = max(1, Int((area.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures one window's full contents, even if partly covered.
    public static func captureWindow(id: CGWindowID) async throws -> (CGImage, Double) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureFailure.notFound("Window \(id) is not on screen. Run `rnest windows`.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Normal app windows on screen, front to back.
    public static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 40, frame.height >= 40,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01
            else { return nil }
            return WindowInfo(id: CGWindowID(number.uint32Value), frame: frame,
                              owner: info[kCGWindowOwnerName as String] as? String ?? "",
                              title: info[kCGWindowName as String] as? String ?? "")
        }
    }

    public static func pngData(_ image: CGImage, scale: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Private

    private static func result(_ image: CGImage, scale: Double) throws -> CaptureResult {
        guard let png = pngData(image, scale: scale) else { throw CaptureFailure.backendFailed("Could not encode PNG.") }
        return CaptureResult(png: png, pixelScale: scale)
    }

    /// Uses the system `screencapture` selection UI (handy for the CLI; the app has its own overlay).
    private func systemInteractive(_ flags: [String]) throws -> CaptureResult {
        let tmp = Shell.temporaryPNG()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run("/usr/sbin/screencapture", flags + ["-x", tmp.path])
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else { throw CaptureFailure.cancelled }
        return CaptureResult(png: data, pixelScale: Self.scale(of: CGMainDisplayID()))
    }
}

private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
#endif
