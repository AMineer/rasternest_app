import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI
import UniformTypeIdentifiers

/// Combine several captures into one PDF (oldest first, one per page).
struct PDFExportSheet: View {
    @ObservedObject var library: CaptureLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String>
    @State private var pageSize: PDFComposer.PageSize = .fit
    @State private var captions = false
    @State private var busy = false

    private var images: [CaptureLibrary.Item] { library.items.filter { !$0.isVideo } }

    init(library: CaptureLibrary) {
        self.library = library
        let images = library.items.filter { !$0.isVideo }
        let today = images.filter { Calendar.current.isDateInToday($0.date) }
        _selected = State(initialValue: Set((today.isEmpty ? Array(images.prefix(10)) : today).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export PDF").font(.title3.weight(.semibold))
            Text("\(selected.count) of \(images.count) captures · one per page, oldest first")
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(images) { item in
                        Toggle(isOn: Binding(
                            get: { selected.contains(item.id) },
                            set: { on in if on { selected.insert(item.id) } else { selected.remove(item.id) } }
                        )) {
                            HStack(spacing: 10) {
                                Group {
                                    if let thumb = library.thumbnails[item.id] {
                                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        Color.secondary.opacity(0.1)
                                    }
                                }
                                .frame(width: 64, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 300)

            HStack {
                Button("Select All") { selected = Set(images.map(\.id)) }
                Button("Select None") { selected = [] }
            }
            .controlSize(.small)

            Picker("Page size", selection: $pageSize) {
                Text("Fit each image").tag(PDFComposer.PageSize.fit)
                Text("US Letter").tag(PDFComposer.PageSize.letter)
                Text("A4").tag(PDFComposer.PageSize.a4)
            }
            .pickerStyle(.segmented)
            Toggle("Add each capture's name as a caption", isOn: $captions)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Exporting…" : "Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 520)
        .tint(Brand.violetColor)
    }

    private func export() {
        EditorWindowController.commitIfOpen()
        let chosen = images.filter { selected.contains($0.id) }.sorted { $0.date < $1.date }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = library.folder
        panel.nameFieldStringValue = "RasterNest Guide \(Date().formatted(.dateTime.year().month().day())).pdf"
            .replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        do {
            var pages: [PDFComposer.Page] = []
            for item in chosen {
                let loaded = try library.load(item)
                guard let flat = AnnotationRenderer(unit: loaded.scale)
                    .flatten(image: loaded.image, annotations: loaded.annotations, effects: loaded.effects) else { continue }
                pages.append(PDFComposer.Page(image: flat, scale: loaded.scale, caption: captions ? item.name : nil))
            }
            try PDFComposer.write(pages, to: url, pageSize: pageSize, title: url.deletingPathExtension().lastPathComponent)
            HUD.show("Saved \(url.lastPathComponent) (\(pages.count) pages)", symbol: "doc.richtext")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        } catch {
            NSAlert(error: error).runModal()
        }
        busy = false
    }
}
