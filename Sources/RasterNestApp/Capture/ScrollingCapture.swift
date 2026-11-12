import AppKit
import CoreMedia
import RasterNestCore
import RasterNestRender
import ScreenCaptureKit
import SwiftUI

/// Records a screen region while the user scrolls and stitches the frames into one tall image.
///
/// RasterNest's own windows (the border and the control panel) are excluded from the stream,
/// and the border ignores the mouse, so scrolling goes straight to the app underneath.
@MainActor
final class ScrollingCaptureSession: NSObject {
    /// Called once with the stitched image (nil when cancelled) and its pixel scale.
    var onFinish: ((CGImage?, CGFloat) -> Void)?

    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Display-local points, origin top-left.
    let region: CGRect
    let scale: CGFloat

    static let maxHeight = 30_000

    private var stream: SCStream?
    private let output = FrameOutput()
    private var border: NSPanel?
    private var panel: NSPanel?
    private let state = ScrollCaptureState()
    private var finished = false

    init(screen: NSScreen, displayID: CGDirectDisplayID, region: CGRect, scale: CGFloat) {
        self.screen = screen
        self.displayID = displayID
        self.region = region.integral
        self.scale = scale
        super.init()
    }

    func start() async throws {
        showBorder()
        showPanel()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplays
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = region
        config.width = Int((region.width * scale).rounded())
        config.height = Int((region.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 4
        config.captureResolution = .best

        output.onFrame = { [weak self] image, signature in
            Task { @MainActor in self?.handle(image, signature) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func finish() { end(cancelled: false) }
    func cancel() { end(cancelled: true) }

    // MARK: Frames

    private func handle(_ image: CGImage, _ signature: RowSignature) {
        guard !finished else { return }
        switch state.stitcher.add(signature) {
        case .first:
            state.first = image
            state.last = image
        case .append(let from, let count):
            // Copy just these rows so the strip doesn't keep the whole frame alive.
            if let crop = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: count)),
               let strip = ScrollCaptureState.ownedCopy(crop) {
                state.strips.append(strip)
            }
            state.last = image
        case .skip:
            break
        }
        state.height = state.stitcher.totalHeight
        state.tooFast = state.stitcher.mismatchStreak >= 3
        state.refreshPreview()
        if state.height >= Self.maxHeight {
            HUD.show("Reached the 30,000 px limit", symbol: "arrow.down.to.line")
            finish()
        }
    }

    private func end(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
        border?.orderOut(nil)
        panel?.orderOut(nil)
        border = nil
        panel = nil
        let result = cancelled ? nil : state.compose()
        onFinish?(result, scale)
        onFinish = nil
    }

    // MARK: Windows

    /// Converts the display-local (top-left) region to Cocoa screen coordinates.
    private var regionInScreen: CGRect {
        CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    private func showBorder() {
        let frame = regionInScreen.insetBy(dx: -4, dy: -4)
        let border = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        border.contentView = NSHostingView(rootView: ScrollBorderView())
        border.orderFrontRegardless()
        self.border = border
    }

    private func showPanel() {
        let view = ScrollControlView(state: state,
                                     onDone: { [weak self] in self?.finish() },
                                     onCancel: { [weak self] in self?.cancel() })
        let host = NSHostingView(rootView: view)
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

        // Beside the region if there's room, otherwise inside its bottom-right corner.
        let r = regionInScreen, visible = screen.visibleFrame, gap: CGFloat = 14
        var origin: CGPoint
        if r.maxX + gap + size.width <= visible.maxX {
            origin = CGPoint(x: r.maxX + gap, y: r.maxY - size.height)
        } else if r.minX - gap - size.width >= visible.minX {
            origin = CGPoint(x: r.minX - gap - size.width, y: r.maxY - size.height)
        } else {
            origin = CGPoint(x: r.maxX - size.width - gap, y: r.minY + gap)
        }
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Shared between the session and its control panel.
@MainActor
final class ScrollCaptureState: ObservableObject {
    var stitcher = ScrollStitcher()
    var first: CGImage?
    var last: CGImage?
    var strips: [CGImage] = []

    @Published var height = 0
    @Published var tooFast = false
    @Published var preview: NSImage?
    private var lastPreview = Date.distantPast

    /// A small "so far" thumbnail, refreshed at most 4× a second.
    func refreshPreview() {
        guard Date().timeIntervalSince(lastPreview) > 0.25, let first else { return }
        lastPreview = Date()
        let width = 120
        let scale = CGFloat(width) / CGFloat(first.width)
        let total = CGFloat(stitcher.totalHeight)
        let height = max(1, Int((total * scale).rounded()))
        guard let ctx = Self.flippedContext(width: width, height: height) else { return }
        ctx.interpolationQuality = .low
        draw(into: ctx, scale: scale)
        if let image = ctx.makeImage() {
            preview = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        }
    }

    /// The full stitched image.
    func compose() -> CGImage? {
        guard let first else { return nil }
        guard let ctx = Self.flippedContext(width: first.width, height: max(first.height, stitcher.totalHeight)) else { return nil }
        draw(into: ctx, scale: 1)
        return ctx.makeImage()
    }

    /// First frame (minus sticky footer), strips, then the footer from the last accepted frame.
    private func draw(into ctx: CGContext, scale: CGFloat) {
        guard let first else { return }
        let footer = stitcher.footer
        let w = CGFloat(first.width) * scale
        var y: CGFloat = 0
        func put(_ image: CGImage?, rows: Range<Int>) {
            guard let image, !rows.isEmpty,
                  let piece = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)) else { return }
            let h = CGFloat(rows.count) * scale
            AnnotationRenderer.drawImage(piece, in: CGRect(x: 0, y: y, width: w, height: h), ctx)
            y += h
        }
        put(first, rows: 0..<(first.height - footer))
        for strip in strips { put(strip, rows: 0..<strip.height) }
        put(last, rows: (first.height - footer)..<first.height)
    }

    /// Redraws an image into its own memory (a crop otherwise retains its whole parent).
    static func ownedCopy(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private static func flippedContext(width: Int, height: Int) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }
}

/// Receives stream frames off the main thread and fingerprints them there.
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.rasternest.scrolling", qos: .userInitiated)
    var onFrame: ((CGImage, RowSignature) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let signature = Self.signature(of: pixelBuffer)
        // Copy the pixels: the stream reuses a small pool of buffers and stalls if we hold on to them.
        guard let image = Self.ownedImage(pixelBuffer) else { return }
        onFrame?(image, signature)
    }

    static func ownedImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Mean luminance of 8 vertical bands for every row (BGRA input).
    static func signature(of buffer: CVPixelBuffer, bands: Int = 8) -> RowSignature {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return RowSignature(rows: height, bands: bands, values: [Float](repeating: 0, count: height * bands))
        }
        var values = [Float](repeating: 0, count: height * bands)
        let bandWidth = max(1, width / bands)
        let step = 3   // sample every 3rd pixel across; every row is kept for pixel-exact offsets
        for row in 0..<height {
            let line = base + row * stride
            for band in 0..<bands {
                let start = band * bandWidth
                let end = band == bands - 1 ? width : start + bandWidth
                var sum = 0, n = 0
                var x = start
                while x < end {
                    let p = line + x * 4
                    sum += (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
                    n += 1
                    x += step
                }
                values[row * bands + band] = n > 0 ? Float(sum) / Float(n) : 0
            }
        }
        return RowSignature(rows: height, bands: bands, values: values)
    }
}

// MARK: - Views

private struct ScrollBorderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Brand.violetColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .padding(1)
    }
}

private struct ScrollControlView: View {
    @ObservedObject var state: ScrollCaptureState
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .foregroundStyle(Brand.violetColor)
                Text("Scrolling capture")
                    .font(.system(size: 13, weight: .semibold))
            }
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
                    if let preview = state.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 70, height: 150, alignment: .bottom)
                            .clipped()
                    }
                }
                .frame(width: 70, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 6) {
                    Text(state.height == 0 ? "Starting…" : "\(state.height.formatted()) px")
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                    Text(state.tooFast ? "Scroll a little slower so frames overlap." : "Scroll down at a steady pace.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(state.tooFast ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Press the scrolling shortcut again to finish.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 150, alignment: .leading)
            }
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.violetColor)
            }
        }
        .padding(14)
        .frame(width: 262)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}
