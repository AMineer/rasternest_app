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

    @discardableResult
    static func autosave(_ image: CGImage, scale: CGFloat) throws -> URL {
        let folder = AppSettings.shared.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(CaptureNaming.timestampedName() + ".png")
        guard let data = ImageCodec.encode(image, format: .png, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func temporaryFile(_ image: CGImage, scale: CGFloat) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RasterNest-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(CaptureNaming.timestampedName() + ".png")
        guard let data = ImageCodec.encode(image, format: .png, scale: scale), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    static func recentCaptures(limit: Int = 8) -> [URL] {
        let folder = AppSettings.shared.saveFolder
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        let images = files.filter { ["png", "jpg", "jpeg", NestDocument.fileExtension].contains($0.pathExtension.lowercased()) }
        let dated = images.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
