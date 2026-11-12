import AppKit
import RasterNestCore
import RasterNestRender
import UniformTypeIdentifiers

/// Everything that brings an image into the editor goes through the capture library,
/// so it shows up in the strip and saves automatically.
@MainActor
enum DocumentOpener {
    static func open(_ url: URL) {
        let library = CaptureLibrary.shared
        library.reload()
        let inLibrary = url.deletingLastPathComponent().standardizedFileURL == library.folder.standardizedFileURL
        do {
            let item: CaptureLibrary.Item
            if url.pathExtension.lowercased() == NestDocument.fileExtension {
                item = library.itemForDocument(url)
            } else if inLibrary, let existing = library.item(withID: url.deletingPathExtension().standardizedFileURL.path) {
                item = existing
            } else {
                item = try library.importImage(url)
            }
            EditorWindowController.show(item)
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
        var loaded: (CGImage, CGFloat)?
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            loaded = ImageCodec.decode(data)
        } else if let ns = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                  let image = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            loaded = (image, max(1, CGFloat(image.width) / max(ns.size.width, 1)))
        }
        guard let (image, scale) = loaded else {
            HUD.show("No image on the clipboard", symbol: "exclamationmark.circle")
            return
        }
        do {
            EditorWindowController.show(try CaptureLibrary.shared.addCapture(image: image, scale: scale))
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
