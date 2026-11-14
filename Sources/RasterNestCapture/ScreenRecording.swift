#if canImport(ScreenCaptureKit)
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes ScreenCaptureKit buffers into an H.264/AAC MP4. Runs on its own queue.
/// Shared by the app's recorder and the headless `rnest record`.
public final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    public let queue = DispatchQueue(label: "app.rasternest.recording", qos: .userInitiated)
    public let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var started = false

    public init(url: URL, width: Int, height: Int, fps: Int = 30, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = max(4_000_000, min(width * height * 6, 40_000_000))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
    public func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                guard self.started, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    cont.resume(returning: nil)
                    return
                }
                // Hold the last frame until now, so a screen that stopped changing still
                // gives a video as long as the recording (SCK only sends frames on change).
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if now.isValid { self.writer.endSession(atSourceTime: now) }
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

/// Records the screen without any UI: a display, an area or a single window, to an MP4.
public final class HeadlessRecorder: @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        /// Display index from `rnest displays`; nil = main display.
        case display(Int?)
        /// Global points, origin top-left of the main display.
        case rect(CGRect)
        /// A window id; only that window is recorded, even when covered.
        case window(UInt32)
    }

    public struct Options: Sendable {
        public var fps: Int
        public var showsCursor: Bool
        public var showClicks: Bool
        public var systemAudio: Bool
        public var microphone: Bool

        public init(fps: Int = 30, showsCursor: Bool = true, showClicks: Bool = true,
                    systemAudio: Bool = false, microphone: Bool = false) {
            self.fps = fps; self.showsCursor = showsCursor; self.showClicks = showClicks
            self.systemAudio = systemAudio; self.microphone = microphone
        }
    }

    public let target: Target
    public let options: Options
    public private(set) var pixelSize = CGSize.zero
    private var stream: SCStream?
    private var writer: RecordingWriter?

    public init(target: Target, options: Options = Options()) {
        self.target = target
        self.options = options
    }

    public func start(to url: URL) async throws {
        await MacScreenCapturer.ensureWindowServerConnection()
        try MacScreenCapturer.requirePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == me }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        var points: CGSize
        var scale: Double
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureFailure.notFound("Window \(id) is not on screen. Run `rnest windows`.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            points = filter.contentRect.size
            scale = Double(filter.pointPixelScale)
        case .display(let index):
            let ids = MacScreenCapturer.activeDisplayIDs()
            let id: CGDirectDisplayID
            if let index {
                guard ids.indices.contains(index) else { throw CaptureFailure.notFound("No display \(index). Run `rnest displays`.") }
                id = ids[index]
            } else {
                id = CGMainDisplayID()
            }
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureFailure.notFound("That display isn't available for recording.")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            points = CGDisplayBounds(id).size
            scale = MacScreenCapturer.scale(of: id)
        case .rect(let rect):
            let ids = MacScreenCapturer.activeDisplayIDs()
            guard let id = ids.max(by: {
                      let a = CGDisplayBounds($0).intersection(rect), b = CGDisplayBounds($1).intersection(rect)
                      return a.width * a.height < b.width * b.height
                  }),
                  !CGDisplayBounds(id).intersection(rect).isNull,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureFailure.notFound("That rectangle is not on any display.")
            }
            let bounds = CGDisplayBounds(id)
            let local = rect.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY).integral
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            sourceRect = local
            points = local.size
            scale = MacScreenCapturer.scale(of: id)
        }

        // H.264 needs even dimensions; keep the longer side within 3840 px.
        let longest = max(points.width, points.height) * scale
        if longest > 3840 { scale *= 3840 / longest }
        let width = max(2, Int((points.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((points.height * scale / 2).rounded()) * 2)
        pixelSize = CGSize(width: width, height: height)

        let fps = max(1, min(options.fps, 60))
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        if case .window = target { config.ignoreShadowsSingleWindow = true }
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

        try? FileManager.default.removeItem(at: url)
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: fps,
                                         systemAudio: options.systemAudio, microphone: useMic)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if options.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if useMic, #available(macOS 15.0, *) {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.writer = writer
        self.stream = stream
    }

    /// Stops and returns the finished MP4.
    public func stop() async throws -> URL {
        let stream = self.stream, writer = self.writer
        self.stream = nil
        self.writer = nil
        try? await stream?.stopCapture()
        guard let url = await writer?.finish() else {
            throw CaptureFailure.backendFailed("Nothing was recorded. If the area didn't change, try again; otherwise check Screen Recording permission.")
        }
        return url
    }
}
#endif
