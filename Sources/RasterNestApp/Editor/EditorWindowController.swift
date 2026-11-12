import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let rasterNestDocument = UTType(filenameExtension: NestDocument.fileExtension, conformingTo: .data) ?? .data
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    let model: EditorModel
    private let canvas: CanvasView
    private let scrollView: NSScrollView
    private var closeAfterSave = false
    private var magnifyObserver: NSObjectProtocol?

    @discardableResult
    static func open(image: CGImage, scale: CGFloat, annotations: [Annotation] = [],
                     fileURL: URL? = nil, title: String? = nil) -> EditorWindowController {
        let model = EditorModel(image: image, pixelScale: scale, annotations: annotations, fileURL: fileURL)
        let controller = EditorWindowController(model: model,
                                                title: title ?? fileURL?.lastPathComponent ?? CaptureNaming.timestampedName())
        openControllers.append(controller)
        controller.present()
        return controller
    }

    init(model: EditorModel, title: String) {
        self.model = model
        canvas = CanvasView(model: model)
        scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = CGSize(width: 780, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let actions = EditorActions(
            copy: { [weak self] in self?.copy(nil) },
            export: { [weak self] in self?.exportImage(nil) },
            save: { [weak self] in self?.saveDocument(nil) },
            zoomFit: { [weak self] in self?.zoomToFit() },
            zoomActual: { [weak self] in self?.zoomActual(nil) },
            zoomIn: { [weak self] in self?.zoomIn(nil) },
            zoomOut: { [weak self] in self?.zoomOut(nil) },
            dragItem: { [weak self] in self?.dragItemProvider() ?? NSItemProvider() }
        )
        let host = NSHostingView(rootView: EditorView(model: model, scrollView: scrollView, actions: actions))
        host.sizingOptions = []
        window.contentView = host

        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncZoom() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present() {
        guard let window else { return }
        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let points = CGSize(width: CGFloat(model.image.width) / model.pixelScale,
                            height: CGFloat(model.image.height) / model.pixelScale)
        let width = min(max(points.width + 60, 860), visible.width * 0.92)
        let height = min(max(points.height + 150, 520), visible.height * 0.92)
        window.setContentSize(CGSize(width: width, height: height))
        let cascade = CGFloat((Self.openControllers.count - 1) % 6) * 24
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2 + cascade,
                                      y: visible.midY - window.frame.height / 2 - cascade))
        ActivationPolicy.becomeRegular()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
        DispatchQueue.main.async { self.zoomToFit() }
    }

    // MARK: Zoom

    func zoomToFit() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = scrollView.contentSize
        let w = CGFloat(model.image.width), h = CGFloat(model.image.height)
        guard w > 0, h > 0, available.width > 0 else { return }
        var m = min((available.width - 32) / w, (available.height - 32) / h)
        m = min(m, 1 / model.pixelScale)   // never blow small captures past 100%
        setMagnification(max(m, 0.05))
    }

    private func setMagnification(_ m: CGFloat) {
        let center = CGPoint(x: scrollView.documentVisibleRect.midX, y: scrollView.documentVisibleRect.midY)
        scrollView.setMagnification(m, centeredAt: center)
        syncZoom()
    }

    private func syncZoom() {
        model.zoomPercent = Int((scrollView.magnification * model.pixelScale * 100).rounded())
        canvas.needsDisplay = true
    }

    @objc func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.25) }
    @objc func zoomActual(_ sender: Any?) { setMagnification(1 / model.pixelScale) }
    @objc func zoomFit(_ sender: Any?) { zoomToFit() }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        guard let image = model.flattened() else { return }
        ImageExport.copyToPasteboard(image, scale: model.pixelScale)
        model.markSaved()
        HUD.show("Copied to clipboard")
    }

    @objc func delete(_ sender: Any?) { model.deleteSelected() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    // MARK: Save / export

    @objc func saveDocument(_ sender: Any?) {
        if let url = model.fileURL {
            write(to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rasterNestDocument]
        panel.nameFieldStringValue = baseName + "." + NestDocument.fileExtension
        panel.message = "A .rasternest file keeps your annotations editable."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                self.write(to: url)
            } else {
                self.closeAfterSave = false
            }
        }
    }

    private func write(to url: URL) {
        do {
            guard let doc = model.makeDocument() else { throw CocoaError(.fileWriteUnknown) }
            try doc.encoded().write(to: url, options: .atomic)
            model.fileURL = url
            model.markSaved()
            window?.title = url.lastPathComponent
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if closeAfterSave { window?.close() }
        } catch {
            closeAfterSave = false
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func exportImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        let formatPicker = FormatPicker(panel: panel, baseName: baseName)
        panel.accessoryView = formatPicker.view
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = baseName + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let format = ExportFormat(fileExtension: url.pathExtension) ?? formatPicker.format
            guard let image = self.model.flattened(),
                  let data = ImageCodec.encode(image, format: format, scale: self.model.pixelScale) else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.model.markSaved()
                HUD.show("Exported \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var baseName: String {
        if let url = model.fileURL { return url.deletingPathExtension().lastPathComponent }
        let title = window?.title ?? CaptureNaming.timestampedName()
        return (title as NSString).deletingPathExtension
    }

    private func dragItemProvider() -> NSItemProvider {
        guard let image = model.flattened(),
              let url = ImageExport.temporaryFile(image, scale: model.pixelScale),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        return provider
    }

    // MARK: Window lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your annotations?"
        alert.informativeText = "You haven't copied, exported or saved this capture since editing it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.closeAfterSave = true
                DispatchQueue.main.async { self.saveDocument(nil) }
            case .alertThirdButtonReturn:
                self.model.markSaved()
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
        Self.openControllers.removeAll { $0 === self }
        ActivationPolicy.refresh()
    }
}

/// PNG/JPEG popup shown in the export panel.
@MainActor
private final class FormatPicker: NSObject {
    let view: NSView
    private let popup = NSPopUpButton()
    private weak var panel: NSSavePanel?
    private let baseName: String

    var format: ExportFormat { popup.indexOfSelectedItem == 1 ? .jpg : .png }

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: ["PNG", "JPEG"])
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
        // Keep the picker alive as long as the panel.
        objc_setAssociatedObject(panel, Unmanaged.passUnretained(self).toOpaque(), self, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func changed() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = baseName + "." + format.rawValue
    }
}
