import AVFoundation
import AVKit
import AppKit
import RasterNestRender
import SwiftUI
import UniformTypeIdentifiers

/// Playback, trimming and export for a screen recording shown in the editor window.
@MainActor
final class VideoPaneModel: ObservableObject {
    let playerView: AVPlayerView = {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }()

    @Published private(set) var item: CaptureLibrary.Item?
    @Published var gifWidth = 800
    @Published var gifFPS = 12.0
    /// 0…1 while a GIF export runs.
    @Published private(set) var progress: Double?
    @Published private(set) var info = ""
    private var exportTask: Task<Void, Never>?

    func load(_ item: CaptureLibrary.Item) {
        guard let url = item.videoURL else { return }
        self.item = item
        playerView.player = AVPlayer(url: url)
        info = ""
        Task {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration).seconds,
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else { return }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            info = "\(Int(size.width)) × \(Int(size.height)) px · \(Self.time(duration)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        }
    }

    func unload() {
        playerView.player?.pause()
        playerView.player = nil
        item = nil
    }

    // MARK: Actions

    func copy() {
        guard let url = item?.videoURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        HUD.show("Copied recording. Paste it into Slack, Mail or Finder", symbol: "film")
    }

    func trim() {
        guard playerView.canBeginTrimming, let item, let url = item.videoURL else { return }
        playerView.beginTrimming { [weak self] result in
            guard result == .okButton, let self,
                  let playerItem = self.playerView.player?.currentItem else { return }
            let start = playerItem.reversePlaybackEndTime.isValid ? playerItem.reversePlaybackEndTime : .zero
            let end = playerItem.forwardPlaybackEndTime.isValid ? playerItem.forwardPlaybackEndTime : playerItem.duration
            Task { await self.applyTrim(url: url, item: item, range: CMTimeRange(start: start, end: end)) }
        }
    }

    private func applyTrim(url: URL, item: CaptureLibrary.Item, range: CMTimeRange) async {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).mp4")
        session.outputURL = temp
        session.outputFileType = .mp4
        session.timeRange = range
        await session.export()
        guard session.status == .completed else {
            HUD.show("Couldn't trim the recording", symbol: "exclamationmark.circle")
            return
        }
        playerView.player = nil
        if let updated = try? CaptureLibrary.shared.replaceVideo(item, with: temp) {
            load(updated)
            HUD.show("Trimmed", symbol: "scissors")
        }
    }

    func exportMP4(from window: NSWindow?) {
        guard let item, let url = item.videoURL, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = item.name + ".mp4"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
                HUD.show("Exported \(dest.lastPathComponent)", symbol: "square.and.arrow.down.fill")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func exportGIF(from window: NSWindow?) {
        guard let item, let url = item.videoURL, let window, progress == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = item.name + ".gif"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            let options = GIFEncoder.Options(fps: self.gifFPS, maxWidth: self.gifWidth == 0 ? nil : self.gifWidth)
            self.progress = 0
            self.exportTask = Task {
                do {
                    try await GIFEncoder.convert(video: url, to: dest, options: options) { value in
                        Task { @MainActor in self.progress = value }
                    }
                    let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    HUD.show("Saved \(dest.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))",
                             symbol: "photo.stack")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: dest)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
                self.progress = nil
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct VideoPane: View {
    @ObservedObject var model: VideoPaneModel
    let window: () -> NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Recording", systemImage: "film")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.info)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { model.trim() } label: { Label("Trim", systemImage: "scissors") }
                    .help("Trim the start and end")
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the recording to paste into Slack, Mail or Finder")
                Button { model.exportMP4(from: window()) } label: { Label("MP4", systemImage: "square.and.arrow.down") }
                    .help("Export the recording as MP4")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            HStack(spacing: 14) {
                Text("GIF").font(.system(size: 12, weight: .semibold))
                Picker("Width", selection: $model.gifWidth) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("1024 px").tag(1024)
                    Text("Original").tag(0)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Frame rate", selection: $model.gifFPS) {
                    Text("10 fps").tag(10.0)
                    Text("12 fps").tag(12.0)
                    Text("15 fps").tag(15.0)
                    Text("20 fps").tag(20.0)
                }
                .pickerStyle(.menu)
                .fixedSize()
                if let progress = model.progress {
                    ProgressView(value: progress)
                        .frame(width: 140)
                    Button("Cancel") { model.cancelExport() }
                } else {
                    Button { model.exportGIF(from: window()) } label: { Label("Export GIF…", systemImage: "photo.stack") }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.violetColor)
                }
                Spacer()
                Text("Smaller width and frame rate make lighter GIFs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)

            Divider()

            PlayerHost(view: model.playerView)
                .background(Color.black)
        }
    }
}

private struct PlayerHost: NSViewRepresentable {
    let view: AVPlayerView
    func makeNSView(context: Context) -> AVPlayerView { view }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
