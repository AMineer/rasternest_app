import ArgumentParser
import Foundation
import RasterNestCapture
import RasterNestCore
#if canImport(RasterNestRender)
import AppKit
import AVFoundation
import CoreGraphics
import RasterNestRender
#endif

/// The building blocks behind `annotate`, `guide` and the MCP server.
enum AgentOps {
    // MARK: images

    /// PNG bytes for any input image (converts JPEG/HEIC/TIFF on macOS).
    static func pngData(_ data: Data, name: String) throws -> Data {
        if PNGInfo(data) != nil { return data }
        #if canImport(RasterNestRender)
        guard let (image, scale) = ImageCodec.decode(data), let png = ImageCodec.encode(image, format: .png, scale: scale) else {
            throw ValidationError("Could not read \(name) as an image.")
        }
        return png
        #else
        throw ValidationError("\(name) isn't a PNG. Only PNG images are supported on this platform.")
        #endif
    }

    /// An editable document for a PNG, a `.rasternest` file, or any image macOS can read.
    static func loadDocument(_ url: URL) throws -> NestDocument {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == NestDocument.fileExtension {
            return try NestDocument.decoded(from: data)
        }
        let png = try pngData(data, name: url.lastPathComponent)
        return NestDocument(imagePNG: png, pixelScale: CGFloat(PNGInfo(png)?.scale ?? 1), annotations: [])
    }

    static func pixelSize(of doc: NestDocument) throws -> CGSize {
        guard let info = PNGInfo(doc.imagePNG) else { throw ValidationError("The document's image isn't a PNG.") }
        return CGSize(width: CGFloat(info.width), height: CGFloat(info.height))
    }

    /// Adds the spec's markup (and frame) to `doc`. OCR runs only when the spec refers to text.
    static func apply(_ spec: AnnotationSpec, to doc: inout NestDocument, ocr cached: OCRResult? = nil) async throws {
        let lines: [TextLine]
        if spec.needsOCR {
            if let cached { lines = cached.lines } else { lines = try await TextRecognition.analyze(imageData: doc.imagePNG).lines }
        } else {
            lines = []
        }
        let size = try pixelSize(of: doc)
        var added = try spec.resolve(imageSize: size, scale: doc.pixelScale, lines: lines,
                                     startingStep: Annotation.nextStepNumber(in: doc.annotations))
        #if canImport(RasterNestRender)
        // Keep labels inside the image now that the real text size is known.
        for i in added.indices where added[i].kind == .text {
            TextMetrics.layout(&added[i])
            let r = added[i].rect
            let dx = min(0, size.width - r.maxX) + max(0, -r.minX)
            let dy = min(0, size.height - r.maxY) + max(0, -r.minY)
            added[i].translate(dx: dx, dy: dy)
        }
        #endif
        doc.annotations += added
        if let effects = try spec.effects(scale: doc.pixelScale) { doc.effects = effects }
    }

    /// Writes `doc` as `.rasternest`, or flattened as PNG/JPEG, based on the extension.
    static func write(_ doc: NestDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if url.pathExtension.lowercased() == NestDocument.fileExtension {
            try doc.encoded().write(to: url, options: .atomic)
            return
        }
        let format = url.pathExtension.lowercased()
        #if canImport(RasterNestRender)
        guard let fmt = ExportFormat(fileExtension: format.isEmpty ? "png" : format) else {
            throw ValidationError("Unsupported output type `.\(format)`. Use .png, .jpg or .rasternest.")
        }
        guard let image = render(doc), let data = ImageCodec.encode(image, format: fmt, scale: doc.pixelScale) else {
            throw CaptureFailure.backendFailed("Rendering failed.")
        }
        try data.write(to: url, options: .atomic)
        #else
        throw CaptureFailure.unsupported("Rendering to .\(format) needs macOS for now. Write a .rasternest file instead.")
        #endif
    }

    #if canImport(RasterNestRender)
    static func render(_ doc: NestDocument) -> CGImage? {
        guard let (base, _) = ImageCodec.decode(doc.imagePNG) else { return nil }
        return AnnotationRenderer(unit: doc.pixelScale).flatten(image: base, annotations: doc.annotations, effects: doc.effects ?? .none)
    }

    /// A small JPEG of an image for an AI model to look at (long side ≤ `maxSide`).
    static func preview(_ image: CGImage, maxSide: Int = 1568) -> Data? {
        let longest = max(image.width, image.height)
        let factor = min(1, Double(maxSide) / Double(longest))
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return ImageCodec.encode(small, format: .jpg, scale: 1, quality: 0.8)
    }
    #endif

    // MARK: capture

    struct Captured {
        var png: Data
        var scale: Double
    }

    /// Captures what a guide step or MCP call describes. Interactive capture only when asked.
    static func capture(_ spec: Guide.CaptureSpec, relativeTo base: URL?, interactive: Bool = false) async throws -> Captured {
        if let file = spec.file {
            let url = resolve(file, relativeTo: base)
            let png = try pngData(Data(contentsOf: url), name: file)
            return Captured(png: png, scale: PNGInfo(png)?.scale ?? 1)
        }
        let capturer = try Capturers.make()
        let target: CaptureTarget
        if spec.window != nil || spec.app != nil {
            target = .window(try await findWindow(spec, capturer: capturer).id)
        } else if let r = spec.rect {
            guard r.count == 4, r[2] > 0, r[3] > 0 else { throw ValidationError("`rect` must be [x, y, width, height].") }
            target = .rect(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
        } else if interactive {
            target = .interactive
        } else {
            target = .fullScreen(display: spec.display)
        }
        let result = try await capturer.capture(target)
        return Captured(png: result.png, scale: result.pixelScale)
    }

    /// The front-most sizable window matching the spec's app / title / window text.
    static func findWindow(_ spec: Guide.CaptureSpec, capturer: ScreenCapturer) async throws -> WindowDescriptor {
        let list = try await capturer.windows()
        func has(_ s: String, _ needle: String?) -> Bool {
            guard let needle, !needle.isEmpty else { return true }
            return s.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let candidates = list.filter { w in
            guard w.width >= 80, w.height >= 60 else { return false }
            if let any = spec.window, !(has(w.owner, any) || has(w.title, any)) { return false }
            return has(w.owner, spec.app) && has(w.title, spec.title)
        }
        guard let match = candidates.first else {
            let wanted = [spec.window, spec.app, spec.title].compactMap { $0 }.joined(separator: " / ")
            let seen = Array(Set(list.map(\.owner))).sorted().prefix(30).joined(separator: ", ")
            throw CaptureFailure.notFound("No on-screen window matches \(wanted). Apps with windows: \(seen)")
        }
        return match
    }

    // MARK: files

    static func resolve(_ path: String, relativeTo base: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || base == nil { return URL(fileURLWithPath: expanded) }
        return base!.appendingPathComponent(expanded).standardizedFileURL
    }

    /// `target` relative to the directory `from`, for links in generated Markdown.
    static func relativePath(_ target: URL, from dir: URL) -> String {
        let t = target.standardizedFileURL.pathComponents, d = dir.standardizedFileURL.pathComponents
        var i = 0
        while i < t.count, i < d.count, t[i] == d[i] { i += 1 }
        guard i > 1 else { return target.path }
        return (Array(repeating: "..", count: d.count - i) + t[i...]).joined(separator: "/")
    }

    /// Runs a guide step's `before` command through the shell.
    static func runShell(_ command: String, in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.standardError // keep stdout clean for MCP and scripts
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw CaptureFailure.backendFailed("`\(command)` exited with status \(p.terminationStatus).")
        }
    }

    // MARK: guides

    struct GuideReport {
        var images: [URL] = []
        var documents: [URL] = []
        var markdown: URL?
        var pdf: URL?
    }

    /// Captures, annotates and writes every step of a guide (or just `only`).
    static func runGuide(at guideURL: URL, only: Set<String> = [], log: (String) -> Void) async throws -> GuideReport {
        let guide = try Guide.decoded(from: Data(contentsOf: guideURL))
        let base = guideURL.deletingLastPathComponent()
        let stemName = guideURL.deletingPathExtension().lastPathComponent
        let outDir = resolve(guide.output ?? "\(stemName)-images", relativeTo: base)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var report = GuideReport()
        for (i, step) in guide.steps.enumerated() {
            let stem = guide.stem(for: i)
            let imageURL = outDir.appendingPathComponent(stem + ".png")
            let docURL = outDir.appendingPathComponent(stem + "." + NestDocument.fileExtension)
            if !only.isEmpty && !only.contains(step.name ?? "") && !only.contains(String(i + 1)) {
                report.images.append(imageURL)
                continue
            }
            log("[\(i + 1)/\(guide.steps.count)] \(step.caption ?? stem)")
            if let before = step.before { try runShell(before, in: base) }
            if let wait = step.wait, wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            let shot = try await capture(step.capture, relativeTo: base)
            var doc = NestDocument(imagePNG: shot.png, pixelScale: CGFloat(shot.scale), annotations: [])
            let spec = AnnotationSpec(frame: step.frame ?? guide.frame, annotations: step.annotations ?? [])
            do {
                try await apply(spec, to: &doc)
            } catch {
                throw ValidationError("Step \(i + 1) (\(stem)): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            try write(doc, to: docURL)
            try write(doc, to: imageURL)
            report.images.append(imageURL)
            report.documents.append(docURL)
        }

        if guide.markdown != "" {
            let mdURL = resolve(guide.markdown ?? "\(stemName).md", relativeTo: base)
            let mdDir = mdURL.deletingLastPathComponent()
            let md = guide.markdown(imagePaths: report.images.map { relativePath($0, from: mdDir) })
            try FileManager.default.createDirectory(at: mdDir, withIntermediateDirectories: true)
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
            report.markdown = mdURL
        }

        #if canImport(RasterNestRender)
        if let pdf = guide.pdf, !pdf.isEmpty {
            let pdfURL = resolve(pdf, relativeTo: base)
            var pages: [PDFComposer.Page] = []
            for (i, url) in report.images.enumerated() {
                guard let (image, scale) = ImageCodec.load(url) else { continue }
                pages.append(PDFComposer.Page(image: image, scale: scale, caption: guide.steps[i].caption))
            }
            try PDFComposer.write(pages, to: pdfURL, pageSize: .fit, title: guide.title)
            report.pdf = pdfURL
        }
        #endif
        return report
    }
}

// MARK: - recording

/// A thread-safe stop flag: set by Ctrl-C, the Return key, a finished `during` command, or a timer.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func set() { lock.lock(); stopped = true; lock.unlock() }
}

extension AgentOps {
    struct RecordRequest {
        var capture = Guide.CaptureSpec()
        var windowID: UInt32?
        /// Seconds to record. Nil: until `during` finishes, or until stopped.
        var duration: Double?
        /// Shell command started once recording is running (drive the UI, open a URL…).
        var during: String?
        var workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var fps = 30
        var cursor = true
        var clicks = true
        var systemAudio = false
        var microphone = false
        /// Where to keep the MP4 (nil = don't keep it).
        var mp4: URL?
        /// Where to write a GIF (nil = no GIF).
        var gif: URL?
        var gifWidth = 800
        var gifFPS = 12.0
        /// Cap for recordings with no duration, so nothing records forever by accident.
        var maxDuration = 600.0
    }

    struct RecordResult {
        var mp4: URL?
        var gif: URL?
        var seconds: Double
        var pixelSize: CGSize
    }

    static func record(_ req: RecordRequest, stop: StopFlag = StopFlag(), log: (String) -> Void) async throws -> RecordResult {
        #if canImport(RasterNestRender)
        guard req.mp4 != nil || req.gif != nil else { throw ValidationError("Choose an MP4 or GIF output.") }
        let target: HeadlessRecorder.Target
        if let id = req.windowID {
            target = .window(id)
        } else if req.capture.window != nil || req.capture.app != nil {
            target = .window(try await findWindow(req.capture, capturer: Capturers.make()).id)
        } else if let r = req.capture.rect {
            guard r.count == 4, r[2] > 0, r[3] > 0 else { throw ValidationError("`rect` must be [x, y, width, height].") }
            target = .rect(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
        } else {
            target = .display(req.capture.display)
        }

        let recorder = HeadlessRecorder(target: target, options: .init(
            fps: req.fps, showsCursor: req.cursor, showClicks: req.clicks,
            systemAudio: req.systemAudio, microphone: req.microphone))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rnest-\(UUID().uuidString).mp4")
        try await recorder.start(to: tmp)
        let started = Date()

        var duringProcess: Process?
        if let during = req.during {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", during]
            p.currentDirectoryURL = req.workingDirectory
            p.standardOutput = FileHandle.standardError
            p.terminationHandler = { _ in
                // A short tail so the last change makes it into the video.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { if req.duration == nil { stop.set() } }
            }
            try p.run()
            duringProcess = p
        }

        let limit = req.duration ?? req.maxDuration
        while !stop.isSet && Date().timeIntervalSince(started) < limit {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let p = duringProcess, p.isRunning { p.terminate() }
        let mp4 = try await recorder.stop()
        let seconds = Date().timeIntervalSince(started)
        log(String(format: "Recorded %.1f s at %d×%d.", seconds, Int(recorder.pixelSize.width), Int(recorder.pixelSize.height)))

        var result = RecordResult(seconds: seconds, pixelSize: recorder.pixelSize)
        if let gif = req.gif {
            try FileManager.default.createDirectory(at: gif.deletingLastPathComponent(), withIntermediateDirectories: true)
            log("Making GIF…")
            try await GIFEncoder.convert(video: mp4, to: gif, options: .init(fps: req.gifFPS, maxWidth: req.gifWidth == 0 ? nil : req.gifWidth))
            result.gif = gif
        }
        if let dest = req.mp4 {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: mp4, to: dest)
            result.mp4 = dest
        } else {
            try? FileManager.default.removeItem(at: mp4)
        }
        return result
        #else
        throw CaptureFailure.unsupported("Screen recording needs macOS for now.")
        #endif
    }

    #if canImport(RasterNestRender)
    /// A frame from the middle of a video, as a small JPEG preview.
    static func videoPreview(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let time = CMTime(seconds: max(0, duration / 2), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return preview(image, maxSide: 1200)
    }
    #endif
}
