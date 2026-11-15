import AppKit
import RasterNestCore
import RasterNestRender
import SwiftUI
import UniformTypeIdentifiers

/// Images waiting to be combined, in order.
@MainActor
final class CombineModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let thumbnail: NSImage
        let pixelSize: CGSize
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    }

    @Published var entries: [Entry] = []
    @Published var arrangement: CombineLayout.Arrangement = .horizontal
    @Published var gap: Double = 24
    @Published var matchSizes = true
    @Published var transparent = false
    @Published var busy = false

    func add(_ url: URL) {
        guard let (image, _) = Self.flattened(url) else { return }
        let thumb = NSImage(cgImage: Self.downscaled(image, maxSide: 360) ?? image, size: .zero)
        entries.append(Entry(url: url, thumbnail: thumb, pixelSize: CGSize(width: image.width, height: image.height)))
    }

    func remove(_ entry: Entry) { entries.removeAll { $0.id == entry.id } }

    func move(_ entry: Entry, by offset: Int) {
        guard let i = entries.firstIndex(of: entry) else { return }
        let j = i + offset
        guard entries.indices.contains(j) else { return }
        entries.swapAt(i, j)
    }

    /// A capture's rendered image (annotations and frame included), or any image file.
    static func flattened(_ url: URL) -> (CGImage, CGFloat)? {
        if url.pathExtension.lowercased() == NestDocument.fileExtension {
            guard let (doc, base) = try? ImageCodec.loadDocument(url),
                  let flat = AnnotationRenderer(unit: doc.pixelScale)
                    .flatten(image: base, annotations: doc.annotations, effects: doc.effects ?? .none) else { return nil }
            return (flat, doc.pixelScale)
        }
        return ImageCodec.load(url)
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let f = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * f)), h = max(1, Int(Double(image.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    var layout: CombineLayout { CombineLayout(arrangement: arrangement, gap: CGFloat(gap), matchSizes: matchSizes) }

    /// Renders the combination and adds it to the library as a new capture.
    func combine(into library: CaptureLibrary) -> CaptureLibrary.Item? {
        let images = entries.compactMap { Self.flattened($0.url) }
        guard images.count >= 2 else { return nil }
        let scale = images.map(\.1).max() ?? 1
        var layout = self.layout
        layout.gap = CGFloat(gap) * scale
        guard let (image, outScale) = ImageCombiner.combine(images, layout: layout,
                                                            background: transparent ? nil : RGBA(1, 1, 1)) else { return nil }
        return try? library.addCapture(image: image, scale: outScale)
    }
}

/// Side panel: drag captures from the strip (or images from Finder) in, arrange, combine.
struct CombinePane: View {
    @ObservedObject var model: CombineModel
    @ObservedObject var library: CaptureLibrary
    let currentItem: CaptureLibrary.Item?
    /// Saves pending edits so dragged captures are up to date.
    let commit: () -> Void
    let onCreated: (CaptureLibrary.Item) -> Void
    let onClose: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Combine").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
            }
            .tint(.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    dropArea
                    if !model.entries.isEmpty { entryList }
                    options
                }
                .padding(12)
            }

            Divider()
            HStack {
                Button("Clear") { model.entries.removeAll() }
                    .disabled(model.entries.isEmpty)
                Spacer()
                Button("Combine") { combine() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.entries.count < 2 || model.busy)
            }
            .padding(12)
        }
        .frame(width: 250)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dropArea: some View {
        VStack(spacing: 8) {
            if model.entries.isEmpty {
                Image(systemName: "square.on.square.dashed").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Drag captures here from the strip, or images from Finder.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                preview.frame(height: 130)
            }
            if let currentItem, !currentItem.isVideo {
                Button("Add Current Capture") {
                    commit()
                    model.add(currentItem.shareURL)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(targeted ? Brand.violetColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            commit()
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add(url) }
                }
            }
            return true
        }
    }

    /// A miniature of the result using the real layout math.
    private var preview: some View {
        GeometryReader { geo in
            let placed = model.layout.place(model.entries.map(\.pixelSize))
            let f = min(geo.size.width / max(placed.canvas.width, 1), geo.size.height / max(placed.canvas.height, 1))
            let canvas = CGSize(width: placed.canvas.width * f, height: placed.canvas.height * f)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(model.transparent ? Color.clear : Color.white)
                    .frame(width: canvas.width, height: canvas.height)
                ForEach(Array(zip(model.entries, placed.frames)), id: \.0.id) { entry, frame in
                    Image(nsImage: entry.thumbnail)
                        .resizable()
                        .frame(width: frame.width * f, height: frame.height * f)
                        .offset(x: frame.minX * f, y: frame.minY * f)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var entryList: some View {
        VStack(spacing: 6) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                    Image(nsImage: entry.thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(entry.url.deletingPathExtension().lastPathComponent)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { model.move(entry, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).help("Move earlier")
                    Button { model.move(entry, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == model.entries.count - 1).help("Move later")
                    Button { model.remove(entry) } label: { Image(systemName: "minus.circle") }
                        .help("Remove")
                }
                .buttonStyle(.borderless)
                .tint(.primary)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.arrangement) {
                ForEach(CombineLayout.Arrangement.allCases, id: \.self) { a in
                    Text(a.title).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text("Gap").foregroundStyle(.secondary)
                Slider(value: $model.gap, in: 0...96).controlSize(.small)
                Text("\(Int(model.gap)) pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38)
            }
            Toggle("Match sizes", isOn: $model.matchSizes).toggleStyle(.checkbox)
            Toggle("Transparent background", isOn: $model.transparent).toggleStyle(.checkbox)
        }
    }

    private func combine() {
        model.busy = true
        defer { model.busy = false }
        guard let item = model.combine(into: library) else {
            HUD.show("Couldn't combine those images", symbol: "exclamationmark.triangle")
            return
        }
        HUD.show("Combined \(model.entries.count) images", symbol: "square.on.square")
        onCreated(item)
    }
}
