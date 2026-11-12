#if canImport(AppKit)
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a video (MP4/MOV) to a looping animated GIF.
public enum GIFEncoder {
    public struct Options: Sendable {
        /// Frames per second in the GIF (GIF timing works in 1/100 s steps).
        public var fps: Double
        /// Output width in pixels; nil keeps the video's width.
        public var maxWidth: Int?
        /// Only convert this part of the video (seconds); nil = whole video.
        public var timeRange: ClosedRange<Double>?

        public init(fps: Double = 12, maxWidth: Int? = 800, timeRange: ClosedRange<Double>? = nil) {
            self.fps = fps
            self.maxWidth = maxWidth
            self.timeRange = timeRange
        }
    }

    public enum Failure: LocalizedError {
        case noVideoTrack, cannotCreateFile, encodingFailed
        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "That file has no video."
            case .cannotCreateFile: return "Couldn't create the GIF file."
            case .encodingFailed: return "Couldn't finish writing the GIF."
            }
        }
    }

    /// Writes `output` and calls `progress` with 0…1 as frames are added.
    public static func convert(video: URL, to output: URL, options: Options = Options(),
                               progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)

        let start = max(0, options.timeRange?.lowerBound ?? 0)
        let end = min(duration, options.timeRange?.upperBound ?? duration)
        let fps = max(1, min(options.fps, 50))
        let delay = (100 / fps).rounded() / 100        // GIF delays are in centiseconds
        let frameCount = max(1, Int(((end - start) / delay).rounded(.down)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        if let maxWidth = options.maxWidth, Int(natural.width) > maxWidth {
            generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: natural.height * CGFloat(maxWidth) / natural.width)
        }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw Failure.cannotCreateFile
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        for i in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: start + Double(i) * delay, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(dest, image, frameProps)
            progress?(Double(i + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodingFailed }
    }
}
#endif
