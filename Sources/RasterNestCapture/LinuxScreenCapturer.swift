#if os(Linux)
import Foundation

/// Linux capture by delegating to whichever screenshot tool is installed.
///
/// Wayland: grim (+ slurp for selection), gnome-screenshot, spectacle.
/// X11:     maim (+ slop), scrot, gnome-screenshot, spectacle, ImageMagick `import`.
public final class LinuxScreenCapturer: ScreenCapturer {
    public enum Backend: String, CaseIterable {
        case grim
        case gnomeScreenshot = "gnome-screenshot"
        case spectacle
        case maim
        case scrot
        case imagemagick = "import"
    }

    public let backend: Backend
    public var name: String { backend.rawValue }

    public init(preferred: String? = nil) throws {
        if let preferred {
            guard let b = Backend(rawValue: preferred) else {
                throw CaptureFailure.noBackend("Unknown backend `\(preferred)`. Options: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard Shell.which(b.rawValue) != nil else { throw CaptureFailure.noBackend("`\(preferred)` is not installed.") }
            backend = b
        } else if let b = Self.detectedBackends().first {
            backend = b
        } else {
            throw CaptureFailure.noBackend(Self.installHint)
        }
    }

    static var isWayland: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WAYLAND_DISPLAY"] != nil || env["XDG_SESSION_TYPE"] == "wayland"
    }

    public static func detectedBackends() -> [Backend] {
        let order: [Backend] = isWayland
            ? [.grim, .gnomeScreenshot, .spectacle]
            : [.maim, .scrot, .gnomeScreenshot, .spectacle, .imagemagick]
        return order.filter { Shell.which($0.rawValue) != nil }
    }

    static let installHint = isWayland
        ? "No screenshot tool found. Install one of: grim + slurp (wlroots/Sway/Hyprland), gnome-screenshot (GNOME), spectacle (KDE)."
        : "No screenshot tool found. Install one of: maim + slop, scrot, gnome-screenshot, spectacle, imagemagick."

    // MARK: ScreenCapturer

    public func displays() async throws -> [DisplayDescriptor] {
        // `xrandr --listmonitors`:  " 0: +*DP-1 2560/597x1440/336+0+0  DP-1"
        guard Shell.which("xrandr") != nil,
              let out = try? Shell.run("xrandr", ["--listmonitors"]).stdoutString else { return [] }
        var result: [DisplayDescriptor] = []
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 3, let geo = Self.parseXrandrGeometry(parts[2]) else { continue }
            let name = parts.last ?? "Display \(result.count)"
            result.append(DisplayDescriptor(index: result.count, id: UInt32(result.count), name: name,
                                            x: geo.x, y: geo.y, width: geo.w, height: geo.h,
                                            scale: 1, isMain: parts[1].contains("*")))
        }
        return result
    }

    public func windows() async throws -> [WindowDescriptor] {
        // `wmctrl -lG`:  "0x03a00007  0 10 20 800 600 host Title words"
        guard Shell.which("wmctrl") != nil else {
            throw CaptureFailure.unsupported(Self.isWayland
                ? "Listing windows isn't possible on Wayland; use `rnest capture --window` to pick one."
                : "Install `wmctrl` to list windows.")
        }
        let out = try Shell.run("wmctrl", ["-lG"]).stdoutString
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 7, let id = UInt32(parts[0].dropFirst(2), radix: 16),
                  let x = Double(parts[2]), let y = Double(parts[3]), let w = Double(parts[4]), let h = Double(parts[5])
            else { return nil }
            let title = parts.count > 7 ? parts[7...].joined(separator: " ") : ""
            return WindowDescriptor(id: id, owner: parts[6], title: title, x: x, y: y, width: w, height: h)
        }
    }

    public func capture(_ target: CaptureTarget) async throws -> CaptureResult {
        let out = Shell.temporaryPNG()
        defer { try? FileManager.default.removeItem(at: out) }
        let path = out.path

        switch (backend, target) {
        // grim (Wayland, wlroots compositors)
        case (.grim, .interactive), (.grim, .interactiveRegion), (.grim, .interactiveWindow):
            let selection = try Shell.run("slurp", [])
            let geometry = selection.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selection.status == 0, !geometry.isEmpty else { throw CaptureFailure.cancelled }
            try runChecked("grim", ["-g", geometry, path])
        case (.grim, .fullScreen(let index)):
            if let index {
                let names = try await displays()
                guard names.indices.contains(index) else { throw CaptureFailure.notFound("No display \(index).") }
                try runChecked("grim", ["-o", names[index].name, path])
            } else {
                try runChecked("grim", [path])
            }
        case (.grim, .rect(let r)):
            try runChecked("grim", ["-g", "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))", path])

        // gnome-screenshot
        case (.gnomeScreenshot, .interactive), (.gnomeScreenshot, .interactiveRegion):
            try runChecked("gnome-screenshot", ["-a", "-f", path])
        case (.gnomeScreenshot, .interactiveWindow):
            try runChecked("gnome-screenshot", ["-w", "-f", path])
        case (.gnomeScreenshot, .fullScreen(nil)):
            try runChecked("gnome-screenshot", ["-f", path])

        // spectacle (KDE)
        case (.spectacle, .interactive), (.spectacle, .interactiveRegion):
            try runChecked("spectacle", ["-b", "-n", "-r", "-o", path])
        case (.spectacle, .interactiveWindow):
            try runChecked("spectacle", ["-b", "-n", "-u", "-o", path])
        case (.spectacle, .fullScreen(nil)):
            try runChecked("spectacle", ["-b", "-n", "-f", "-o", path])

        // maim (X11)
        case (.maim, .interactive), (.maim, .interactiveRegion), (.maim, .interactiveWindow):
            try runChecked("maim", ["-s", path])
        case (.maim, .fullScreen(nil)):
            try runChecked("maim", [path])
        case (.maim, .rect(let r)):
            try runChecked("maim", ["-g", "\(Int(r.width))x\(Int(r.height))+\(Int(r.minX))+\(Int(r.minY))", path])
        case (.maim, .window(let id)):
            try runChecked("maim", ["-i", String(id), path])

        // scrot (X11)
        case (.scrot, .interactive), (.scrot, .interactiveRegion), (.scrot, .interactiveWindow):
            try runChecked("scrot", ["-s", "-o", path])
        case (.scrot, .fullScreen(nil)):
            try runChecked("scrot", ["-o", path])

        // ImageMagick import (X11)
        case (.imagemagick, .interactive), (.imagemagick, .interactiveRegion), (.imagemagick, .interactiveWindow):
            try runChecked("import", [path])
        case (.imagemagick, .fullScreen(nil)):
            try runChecked("import", ["-window", "root", path])
        case (.imagemagick, .rect(let r)):
            try runChecked("import", ["-window", "root", "-crop", "\(Int(r.width))x\(Int(r.height))+\(Int(r.minX))+\(Int(r.minY))", path])
        case (.imagemagick, .window(let id)):
            try runChecked("import", ["-window", String(id), path])

        default:
            throw CaptureFailure.unsupported("The `\(backend.rawValue)` backend can't do that capture. Try --backend with one of: \(Self.detectedBackends().map(\.rawValue).joined(separator: ", ")).")
        }

        guard let data = try? Data(contentsOf: out), !data.isEmpty else { throw CaptureFailure.cancelled }
        return CaptureResult(png: data, pixelScale: 1)
    }

    // MARK: Helpers

    private func runChecked(_ tool: String, _ args: [String]) throws {
        let result = try Shell.run(tool, args)
        if result.status != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // Most tools exit non-zero when the user presses Esc during selection.
            if message.isEmpty || message.lowercased().contains("cancel") { throw CaptureFailure.cancelled }
            throw CaptureFailure.backendFailed("\(tool) failed: \(message)")
        }
    }

    /// Parses "2560/597x1440/336+0+0".
    static func parseXrandrGeometry(_ s: String) -> (x: Double, y: Double, w: Double, h: Double)? {
        let plusParts = s.split(separator: "+")
        guard plusParts.count == 3, let x = Double(plusParts[1]), let y = Double(plusParts[2]) else { return nil }
        let dims = plusParts[0].split(separator: "x")
        guard dims.count == 2,
              let w = Double(dims[0].split(separator: "/")[0]),
              let h = Double(dims[1].split(separator: "/")[0]) else { return nil }
        return (x, y, w, h)
    }
}
#endif
