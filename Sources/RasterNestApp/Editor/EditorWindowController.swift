import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let rasterNestDocument = UTType(filenameExtension: NestDocument.fileExtension, conformingTo: .data) ?? .data
}

/// What the single editor window is showing.
@MainActor
final class EditorSession: ObservableObject {
    @Published var model: EditorModel
    @Published var item: CaptureLibrary.Item?

    init(model: EditorModel) { self.model = model }
}

/// The one editor window. New captures load into it; the strip on the left switches between
/// recent captures. Edits are saved automatically (switching, closing, leaving the window).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: EditorWindowController?
    static var shared: EditorWindowController {
        if let instance { return instance }
        let controller = EditorWindowController()
        instance = controller
        return controller
    }

    /// Saves pending edits, e.g. before quitting.
    static func commitIfOpen() { instance?.commitCurrent() }

    static func show(_ item: CaptureLibrary.Item) { shared.open(item) }

    let session: EditorSession
    let video = VideoPaneModel()
    private var canvas: CanvasView
    private let scrollView: NSScrollView
    private var magnifyObserver: NSObjectProtocol?
    private var hasBeenShown = false

    var model: EditorModel { session.model }

    private init() {
        let placeholder = EditorModel(image: Self.blankImage(), pixelScale: 1)
        session = EditorSession(model: placeholder)
        canvas = CanvasView(model: placeholder)
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

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "RasterNest"
        window.minSize = CGSize(width: 960, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("RasterNestEditor")
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
        let root = EditorRootView(
            session: session, library: CaptureLibrary.shared, video: video, scrollView: scrollView, actions: actions,
            window: { [weak window] in window },
            onSelect: { [weak self] item in self?.open(item) },
            onTrash: { [weak self] item in self?.trash(item) }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host

        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncZoom() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Switching captures

    func open(_ item: CaptureLibrary.Item) {
        if item.isVideo {
            if session.item?.id != item.id {
                commitCurrent()
                session.item = item
                video.load(item)
                window?.title = item.name
                window?.representedURL = nil
            }
            present()
            return
        }
        if session.item?.isVideo == true { video.unload() }
        if session.item?.id != item.id {
            commitCurrent()
            do {
                let loaded = try CaptureLibrary.shared.load(item)
                install(EditorModel(image: loaded.image, pixelScale: loaded.scale,
                                    annotations: loaded.annotations, fileURL: item.documentURL,
                                    effects: loaded.effects), item: item)
            } catch {
                present(error)
                return
            }
        }
        present()
    }

    private func install(_ model: EditorModel, item: CaptureLibrary.Item) {
        session.model = model
        session.item = item
        canvas = CanvasView(model: model)
        scrollView.documentView = canvas
        window?.title = item.name
        window?.representedURL = item.isExternal ? item.documentURL : nil
        window?.makeFirstResponder(canvas)
        DispatchQueue.main.async { self.zoomToFit() }
    }

    /// Saves the current capture if it changed.
    func commitCurrent() {
        guard let item = session.item, !item.isVideo, model.isDirty else { return }
        do {
            session.item = try CaptureLibrary.shared.save(model, as: item)
            model.markSaved()
        } catch {
            NSLog("RasterNest: could not save \(item.name): \(error)")
        }
    }

    private func trash(_ item: CaptureLibrary.Item) {
        let library = CaptureLibrary.shared
        let wasCurrent = session.item?.id == item.id
        let index = library.items.firstIndex { $0.id == item.id } ?? 0
        if wasCurrent { model.markSaved() }   // don't resurrect it on the next commit
        if wasCurrent && item.isVideo { video.unload() }
        library.moveToTrash(item)
        guard wasCurrent else { return }
        session.item = nil
        if library.items.isEmpty {
            window?.close()
        } else {
            open(library.items[min(index, library.items.count - 1)])
        }
    }

    private func present() {
        guard let window else { return }
        if !hasBeenShown {
            hasBeenShown = true
            if !window.setFrameUsingName("RasterNestEditor") {
                let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                let size = CGSize(width: min(1280, visible.width * 0.88), height: min(860, visible.height * 0.88))
                window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                       width: size.width, height: size.height), display: false)
            }
        }
        ActivationPolicy.becomeRegular()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
    }

    private func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    // MARK: Zoom

    func zoomToFit() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = scrollView.contentSize
        let w = canvas.frame.width, h = canvas.frame.height
        guard w > 0, h > 0, available.width > 0 else { return }
        var m = min((available.width - 32) / w, (available.height - 32) / h)
        m = min(m, 1 / model.pixelScale)   // never blow small captures past 100%
        // Very tall captures (scrolling) fit to width instead, so they stay readable.
        if h / w > 3 { m = min((available.width - 32) / w, 1 / model.pixelScale) }
        setMagnification(max(m, 0.05))
        if h / w > 3 { canvas.scroll(.zero) }
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

    private var showingVideo: Bool { session.item?.isVideo == true }

    @objc func copy(_ sender: Any?) {
        if showingVideo { video.copy(); return }
        guard let image = model.flattened() else { return }
        ImageExport.copyToPasteboard(image, scale: model.pixelScale)
        commitCurrent()
        HUD.show("Copied to clipboard")
    }

    @objc func delete(_ sender: Any?) { model.deleteSelected() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    // MARK: Save / export

    /// Captures save themselves; ⌘S just does it now.
    @objc func saveDocument(_ sender: Any?) {
        guard !showingVideo else { return }
        commitCurrent()
        HUD.show("Saved", symbol: "checkmark.circle.fill", duration: 0.9)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rasterNestDocument]
        panel.nameFieldStringValue = baseName + "." + NestDocument.fileExtension
        panel.message = "Saves an editable copy of this capture."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                guard let doc = self.model.makeDocument() else { throw CocoaError(.fileWriteUnknown) }
                try doc.encoded().write(to: url, options: .atomic)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                HUD.show("Saved \(url.lastPathComponent)")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func exportImage(_ sender: Any?) {
        if showingVideo { video.exportMP4(from: window); return }
        guard let window else { return }
        let panel = NSSavePanel()
        let formatPicker = FormatPicker(panel: panel, baseName: baseName)
        panel.accessoryView = formatPicker.view
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = baseName + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let image = self.model.flattened() else { return }
            do {
                if url.pathExtension.lowercased() == "pdf" || formatPicker.isPDF {
                    try PDFComposer.write([PDFComposer.Page(image: image, scale: self.model.pixelScale)], to: url,
                                          title: url.deletingPathExtension().lastPathComponent)
                } else {
                    let format = ExportFormat(fileExtension: url.pathExtension) ?? formatPicker.format
                    guard let data = ImageCodec.encode(image, format: format, scale: self.model.pixelScale) else { return }
                    try data.write(to: url, options: .atomic)
                }
                self.commitCurrent()
                HUD.show("Exported \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private var baseName: String { session.item?.name ?? CaptureNaming.timestampedName() }

    private func dragItemProvider() -> NSItemProvider {
        guard let image = model.flattened(),
              let url = ImageExport.temporaryFile(image, scale: model.pixelScale),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        return provider
    }

    // MARK: Window lifecycle

    func windowDidResignKey(_ notification: Notification) {
        // Keep the PNG on disk current when you switch to your docs app to paste it.
        commitCurrent()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        CaptureLibrary.shared.reload()
    }

    func windowWillClose(_ notification: Notification) {
        commitCurrent()
        video.playerView.player?.pause()
        ActivationPolicy.refresh()
    }

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        return ctx.makeImage()!
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
    var isPDF: Bool { popup.indexOfSelectedItem == 2 }

    init(panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: ["PNG", "JPEG", "PDF"])
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
        panel.allowedContentTypes = [isPDF ? .pdf : format.utType]
        panel.nameFieldStringValue = baseName + "." + (isPDF ? "pdf" : format.rawValue)
    }
}
