import AppKit
import RasterNestCore
import RasterNestRender
import UniformTypeIdentifiers

@MainActor
enum DocumentOpener {
    static func open(_ url: URL) {
        do {
            if url.pathExtension.lowercased() == NestDocument.fileExtension {
                let (doc, image) = try ImageCodec.loadDocument(url)
                EditorWindowController.open(image: image, scale: doc.pixelScale, annotations: doc.annotations, fileURL: url)
            } else if let (image, scale) = ImageCodec.load(url) {
                EditorWindowController.open(image: image, scale: scale, title: url.lastPathComponent)
            } else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    static func presentOpenPanel() {
        ActivationPolicy.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rasterNestDocument, .png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { ActivationPolicy.refresh(); return }
        panel.urls.forEach(open)
    }

    static func openFromClipboard() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let (image, scale) = ImageCodec.decode(data) {
            EditorWindowController.open(image: image, scale: scale)
        } else if let ns = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                  let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = max(1, CGFloat(image.width) / max(ns.size.width, 1))
            EditorWindowController.open(image: image, scale: scale)
        } else {
            HUD.show("No image on the clipboard", symbol: "exclamationmark.circle")
        }
    }
}
