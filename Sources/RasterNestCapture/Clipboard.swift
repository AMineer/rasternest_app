import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum Clipboard {
    public static func copyPNG(_ png: Data) throws {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        #else
        try linuxCopy(png, mime: "image/png")
        #endif
    }

    public static func copyText(_ text: String) throws {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #else
        try linuxCopy(Data(text.utf8), mime: "text/plain;charset=utf-8")
        #endif
    }

    #if !canImport(AppKit)
    private static func linuxCopy(_ data: Data, mime: String) throws {
        let env = ProcessInfo.processInfo.environment
        let wayland = env["WAYLAND_DISPLAY"] != nil
        // Clipboard tools keep a child alive to serve the selection, so don't wait on their pipes.
        if wayland, Shell.which("wl-copy") != nil {
            try Shell.run("wl-copy", ["--type", mime], stdin: data, captureOutput: false)
        } else if Shell.which("xclip") != nil {
            try Shell.run("xclip", ["-selection", "clipboard", "-t", mime, "-i"], stdin: data, captureOutput: false)
        } else if mime.hasPrefix("text"), Shell.which("xsel") != nil {
            try Shell.run("xsel", ["--clipboard", "--input"], stdin: data, captureOutput: false)
        } else {
            throw CaptureFailure.noBackend(wayland
                ? "Install `wl-clipboard` to copy to the clipboard."
                : "Install `xclip` to copy to the clipboard.")
        }
    }
    #endif
}
