import AppKit
import RasterNestCore
import RasterNestRender

/// App-side helpers for getting images out: clipboard, autosave, drag-out temp files.
@MainActor
enum ImageExport {
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = ImageCodec.encode(image, format: .png, scale: scale) { pb.setData(png, forType: .png) }
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = NSImage(cgImage: image, size: pointSize).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func temporaryFile(_ image: CGImage, scale: CGFloat) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RasterNest-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(CaptureNaming.timestampedName() + ".png")
        guard let data = ImageCodec.encode(image, format: .png, scale: scale), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
