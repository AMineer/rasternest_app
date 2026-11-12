import AppKit
import RasterNestRender
import SwiftUI

/// Editor window layout: recent captures on the left, the editor on the right.
struct EditorRootView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var library: CaptureLibrary
    let video: VideoPaneModel
    let scrollView: NSScrollView
    let actions: EditorActions
    let window: () -> NSWindow?
    let onSelect: (CaptureLibrary.Item) -> Void
    let onTrash: (CaptureLibrary.Item) -> Void

    var body: some View {
        HStack(spacing: 0) {
            CaptureStrip(library: library, selectedID: session.item?.id, onSelect: onSelect, onTrash: onTrash)
            Divider()
            if session.item?.isVideo == true {
                VideoPane(model: video, window: window)
            } else {
                EditorView(model: session.model, scrollView: scrollView, actions: actions)
                    .id(ObjectIdentifier(session.model))
            }
        }
        .tint(Brand.violetColor)
    }
}

/// The strip of recent captures. Click to edit, drag into another app, right-click for more.
struct CaptureStrip: View {
    @ObservedObject var library: CaptureLibrary
    let selectedID: String?
    let onSelect: (CaptureLibrary.Item) -> Void
    let onTrash: (CaptureLibrary.Item) -> Void
    @State private var showPDF = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Captures")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(library.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showPDF = true } label: { Image(systemName: "doc.richtext") }
                    .buttonStyle(.borderless)
                    .help("Combine captures into a PDF")
                    .disabled(library.items.allSatisfy(\.isVideo))
                Button {
                    try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(library.folder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show the captures folder in Finder")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            if library.items.isEmpty {
                Text("Captures you take appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(library.items) { item in
                                CaptureThumb(item: item, image: library.thumbnails[item.id], selected: item.id == selectedID)
                                    .id(item.id)
                                    .onTapGesture { onSelect(item) }
                                    .onDrag { NSItemProvider(contentsOf: item.shareURL) ?? NSItemProvider() }
                                    .contextMenu { menu(for: item) }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 172)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showPDF) { PDFExportSheet(library: library) }
    }

    @ViewBuilder
    private func menu(for item: CaptureLibrary.Item) -> some View {
        Button("Edit") { onSelect(item) }
        Button("Copy Image") { copy(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.shareURL]) }
        Divider()
        Button(item.isExternal ? "Remove from List" : "Move to Trash", role: .destructive) { onTrash(item) }
    }

    private func copy(_ item: CaptureLibrary.Item) {
        if let video = item.videoURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([video as NSURL])
            HUD.show("Copied recording", symbol: "film")
            return
        }
        guard let url = item.imageURL, let (image, scale) = ImageCodec.load(url) else { return }
        ImageExport.copyToPasteboard(image, scale: scale)
        HUD.show("Copied to clipboard")
    }
}

private struct CaptureThumb: View {
    let item: CaptureLibrary.Item
    let image: NSImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                } else {
                    ProgressView().controlSize(.small)
                }
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
            }
            .frame(height: 100)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Brand.violetColor : Color.clear, lineWidth: 2.5)
            )
            HStack(spacing: 4) {
                if item.isExternal { Image(systemName: "doc").font(.system(size: 9)) }
                Text(label)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .help(item.name)
    }

    private var label: String {
        if Calendar.current.isDateInToday(item.date) {
            return item.date.formatted(date: .omitted, time: .shortened)
        }
        return item.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
