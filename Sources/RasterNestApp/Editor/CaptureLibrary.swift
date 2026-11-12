import AVFoundation
import AppKit
import ImageIO
import RasterNestCore
import RasterNestRender

/// The captures folder, as the list shown in the editor's strip.
///
/// Each capture is stored as `Name.rasternest` (editable: original pixels + annotations) and,
/// when "Keep a PNG" is on, `Name.png` (the rendered result, refreshed on every save) so the
/// folder always holds ready-to-use images for docs.
@MainActor
final class CaptureLibrary: ObservableObject {
    static let shared = CaptureLibrary()

    struct Item: Identifiable, Hashable {
        /// Path of the capture without extension; stable across the .rasternest/.png pair.
        let id: String
        let name: String
        var documentURL: URL
        var imageURL: URL?
        /// A screen recording (MP4/MOV). Recordings play in the video pane instead of the image editor.
        var videoURL: URL?
        var date: Date
        /// A .rasternest opened from outside the captures folder; edited in place.
        var isExternal = false

        var isVideo: Bool { videoURL != nil }
        var hasDocument: Bool { FileManager.default.fileExists(atPath: documentURL.path) }
        /// Best file to hand to other apps (drag, Finder).
        var shareURL: URL { videoURL ?? imageURL ?? documentURL }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    private var externalItems: [Item] = []

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov"]
    static let limit = 300

    var folder: URL { AppSettings.shared.saveFolder }

    // MARK: Listing

    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var byBase: [String: Item] = [:]
        for url in files {
            let ext = url.pathExtension.lowercased()
            let isDoc = ext == NestDocument.fileExtension
            let isVideo = Self.videoExtensions.contains(ext)
            guard isDoc || isVideo || Self.imageExtensions.contains(ext) else { continue }
            let base = url.deletingPathExtension()
            let key = base.standardizedFileURL.path
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            var item = byBase[key] ?? Item(id: key, name: base.lastPathComponent,
                                           documentURL: base.appendingPathExtension(NestDocument.fileExtension),
                                           imageURL: nil, date: date)
            if isVideo {
                item.videoURL = url
            } else if !isDoc, item.imageURL == nil || ext == "png" {
                item.imageURL = url
            }
            item.date = min(item.date, date)
            byBase[key] = item
        }
        let sorted = byBase.values.sorted { ($0.date, $0.name) > ($1.date, $1.name) }
        items = externalItems + sorted.prefix(Self.limit)
        for item in items where thumbnails[item.id] == nil { loadThumbnail(item) }
    }

    func item(withID id: String) -> Item? { items.first { $0.id == id } }

    // MARK: Adding

    /// Stores a fresh capture and returns its item (newest first in the strip).
    @discardableResult
    func addCapture(image: CGImage, scale: CGFloat, name: String = CaptureNaming.timestampedName()) throws -> Item {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = uniqueBase(name)
        guard let doc = ImageCodec.makeDocument(image: image, scale: scale, annotations: []) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let docURL = base.appendingPathExtension(NestDocument.fileExtension)
        try doc.encoded().write(to: docURL, options: .atomic)
        var pngURL: URL?
        if AppSettings.shared.keepPNG {
            let url = base.appendingPathExtension("png")
            try doc.imagePNG.write(to: url, options: .atomic)
            pngURL = url
        }
        let item = Item(id: base.standardizedFileURL.path, name: base.lastPathComponent,
                        documentURL: docURL, imageURL: pngURL, date: Date())
        items.insert(item, at: externalItems.count)
        thumbnails[item.id] = Self.thumbnail(data: doc.imagePNG)
        return item
    }

    /// Moves a finished recording into the captures folder.
    @discardableResult
    func addRecording(_ tempURL: URL, name: String = CaptureNaming.timestampedName()) throws -> Item {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = uniqueBase(name)
        let url = base.appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: tempURL, to: url)
        let item = Item(id: base.standardizedFileURL.path, name: base.lastPathComponent,
                        documentURL: base.appendingPathExtension(NestDocument.fileExtension),
                        imageURL: nil, videoURL: url, date: Date())
        items.insert(item, at: externalItems.count)
        loadThumbnail(item)
        return item
    }

    /// Replaces a recording's file (after trimming).
    func replaceVideo(_ item: Item, with newFile: URL) throws -> Item {
        guard let url = item.videoURL else { return item }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: newFile)
        thumbnails[item.id] = nil
        loadThumbnail(item)
        return item
    }

    /// Opening an image from elsewhere copies it into the library so edits never touch the original.
    func importImage(_ url: URL) throws -> Item {
        guard let (image, scale) = ImageCodec.load(url) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        return try addCapture(image: image, scale: scale, name: url.deletingPathExtension().lastPathComponent)
    }

    /// A .rasternest document: library ones map to their item; others are edited in place.
    func itemForDocument(_ url: URL) -> Item {
        let key = url.deletingPathExtension().standardizedFileURL.path
        if let existing = item(withID: key) { return existing }
        let item = Item(id: key, name: url.deletingPathExtension().lastPathComponent, documentURL: url,
                        imageURL: nil, date: Date(), isExternal: true)
        externalItems.removeAll { $0.id == key }
        externalItems.insert(item, at: 0)
        items = externalItems + items.filter { !$0.isExternal }
        loadThumbnail(item)
        return item
    }

    // MARK: Loading and saving

    func load(_ item: Item) throws -> (image: CGImage, scale: CGFloat, annotations: [Annotation]) {
        if item.hasDocument {
            let (doc, image) = try ImageCodec.loadDocument(item.documentURL)
            return (image, doc.pixelScale, doc.annotations)
        }
        if let url = item.imageURL, let (image, scale) = ImageCodec.load(url) {
            return (image, scale, [])
        }
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: item.documentURL.path])
    }

    /// Writes the editable document and refreshes the rendered PNG and thumbnail.
    @discardableResult
    func save(_ model: EditorModel, as item: Item) throws -> Item {
        guard let doc = model.makeDocument() else { throw CocoaError(.fileWriteUnknown) }
        try doc.encoded().write(to: item.documentURL, options: .atomic)
        var updated = item
        if let flat = model.flattened(), let png = ImageCodec.encode(flat, format: .png, scale: model.pixelScale) {
            if !item.isExternal && AppSettings.shared.keepPNG {
                let url = item.imageURL?.pathExtension.lowercased() == "png"
                    ? item.imageURL!
                    : item.documentURL.deletingPathExtension().appendingPathExtension("png")
                try png.write(to: url, options: .atomic)
                updated.imageURL = url
            }
            thumbnails[item.id] = Self.thumbnail(data: png)
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
        if let i = externalItems.firstIndex(where: { $0.id == item.id }) { externalItems[i] = updated }
        return updated
    }

    func moveToTrash(_ item: Item) {
        let fm = FileManager.default
        if !item.isExternal {
            let gif = item.videoURL?.deletingPathExtension().appendingPathExtension("gif")
            for url in [item.documentURL, item.imageURL, item.videoURL, gif].compactMap({ $0 }) where fm.fileExists(atPath: url.path) {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }
        externalItems.removeAll { $0.id == item.id }
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
    }

    // MARK: Thumbnails

    private func loadThumbnail(_ item: Item) {
        let imageURL = item.imageURL, docURL = item.documentURL, videoURL = item.videoURL, id = item.id
        Task.detached(priority: .utility) {
            let thumb: NSImage?
            if let videoURL {
                thumb = await Self.videoThumbnail(videoURL)
            } else {
                thumb = Self.thumbnail(imageURL: imageURL, documentURL: docURL)
            }
            await MainActor.run { if let thumb { CaptureLibrary.shared.thumbnails[id] = thumb } }
        }
    }

    nonisolated static func thumbnail(imageURL: URL?, documentURL: URL) -> NSImage? {
        if let imageURL, let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) {
            return thumbnail(source: source)
        }
        guard let data = try? Data(contentsOf: documentURL),
              let doc = try? NestDocument.decoded(from: data) else { return nil }
        return thumbnail(data: doc.imagePNG)
    }

    nonisolated static func videoThumbnail(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let cg = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func thumbnail(data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: source)
    }

    nonisolated private static func thumbnail(source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func uniqueBase(_ name: String) -> URL {
        let fm = FileManager.default
        var base = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: base.appendingPathExtension(NestDocument.fileExtension).path)
                || fm.fileExists(atPath: base.appendingPathExtension("png").path)
                || fm.fileExists(atPath: base.appendingPathExtension("mp4").path) {
            base = folder.appendingPathComponent("\(name) (\(n))")
            n += 1
        }
        return base
    }
}
