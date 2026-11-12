import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Records a screen area to an H.264 MP4 (optionally with system audio and microphone).
///
/// RasterNest's own windows (border, timer panel, countdown) are excluded from the recording.
@MainActor
final class RecordingSession: NSObject {
    struct Options {
        var systemAudio = false
        var microphone = false
        var showClicks = true
    }

    /// Called once with the finished file (nil when discarded or failed).
    var onFinish: ((URL?) -> Void)?

    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Display-local points, origin top-left.
    let region: CGRect
    let scale: CGFloat
    let options: Options
    let isFullDisplay: Bool

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var border: NSPanel?
    private var panel: NSPanel?
    private let state = RecordingState()
    private var timer: Timer?
    private var finished = false

    init(screen: NSScreen, displayID: CGDirectDisplayID, region: CGRect, scale: CGFloat, options: Options) {
        self.screen = screen
        self.displayID = displayID
        self.region = region.integral
        self.scale = scale
        self.options = options
        self.isFullDisplay = region.integral.size == screen.frame.size
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplays }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // H.264 needs even dimensions; keep the longer side within 3840 px.
        var pixelScale = scale
        let longest = max(region.width, region.height) * pixelScale
        if longest > 3840 { pixelScale *= 3840 / longest }
        let width = Int((region.width * pixelScale / 2).rounded()) * 2
        let height = Int((region.height * pixelScale / 2).rounded()) * 2

        let config = SCStreamConfiguration()
        if !isFullDisplay { config.sourceRect = region }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        if #available(macOS 15.0, *) { config.showMouseClicks = options.showClicks }
        if options.systemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        var useMic = false
        if options.microphone, #available(macOS 15.0, *) {
            config.captureMicrophone = true
            useMic = true
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RasterNest-recording-\(UUID().uuidString).mp4")
        let writer = try RecordingWriter(url: url, width: width, height: height,
                                         systemAudio: options.systemAudio, microphone: useMic)
        self.writer = writer

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if options.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if useMic, #available(macOS 15.0, *) {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.stream = stream

        showBorder()
        showPanel()
        state.started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.tick() }
        }
    }

    func stop() { end(discard: false) }
    func discard() { end(discard: true) }

    private func end(discard: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        border?.orderOut(nil)
        panel?.orderOut(nil)
        border = nil
        panel = nil
        let stream = self.stream, writer = self.writer
        self.stream = nil
        Task {
            try? await stream?.stopCapture()
            let url = await writer?.finish()
            if discard, let url { try? FileManager.default.removeItem(at: url) }
            self.onFinish?(discard ? nil : url)
            self.onFinish = nil
        }
    }

    // MARK: Windows

    private var regionInScreen: CGRect {
        CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    private func showBorder() {
        guard !isFullDisplay else { return }
        let border = NSPanel(contentRect: regionInScreen.insetBy(dx: -4, dy: -4),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(1))
        border.orderFrontRegardless()
        self.border = border
    }

    private func showPanel() {
        let host = NSHostingView(rootView: RecordingControlView(state: state,
                                                                onStop: { [weak self] in self?.stop() },
                                                                onDiscard: { [weak self] in self?.discard() }))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        // Under the area if there's room, else above it, else at the bottom of the screen.
        let r = regionInScreen, visible = screen.visibleFrame, gap: CGFloat = 12
        var origin = CGPoint(x: r.midX - size.width / 2, y: r.minY - gap - size.height)
        if isFullDisplay || origin.y < visible.minY {
            origin.y = r.maxY + gap
            if isFullDisplay || origin.y + size.height > visible.maxY { origin.y = visible.minY + 24 }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

@MainActor
final class RecordingState: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    var started: Date?
    func tick() { if let started { elapsed = Date().timeIntervalSince(started) } }
}

/// Writes ScreenCaptureKit buffers into an MP4. Runs on its own queue.
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.rasternest.recording", qos: .userInitiated)
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(4_000_000, min(width * height * 6, 40_000_000))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        self.systemAudio = systemAudio ? audioInput() : nil
        self.microphone = microphone ? audioInput() : nil
        if let a = self.systemAudio { writer.add(a) }
        if let m = self.microphone { writer.add(m) }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                started = true
            }
            if video.isReadyForMoreMediaData { video.append(sampleBuffer) }
        case .audio:
            if started, let a = systemAudio, a.isReadyForMoreMediaData { a.append(sampleBuffer) }
        default:
            if #available(macOS 15.0, *), type == .microphone,
               started, let m = microphone, m.isReadyForMoreMediaData { m.append(sampleBuffer) }
        }
    }

    /// Finishes the file. Returns nil if nothing was recorded.
    func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard self.started, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    cont.resume(returning: nil)
                    return
                }
                self.video.markAsFinished()
                self.systemAudio?.markAsFinished()
                self.microphone?.markAsFinished()
                self.writer.finishWriting {
                    cont.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }
}

private struct RecordingControlView: View {
    @ObservedObject var state: RecordingState
    let onStop: () -> Void
    let onDiscard: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(Self.format(state.elapsed))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop and open the recording (or press the record shortcut again)")
            Button(action: onDiscard) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Discard this recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
