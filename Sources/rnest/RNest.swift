import ArgumentParser
import Foundation
import RasterNestCapture
import RasterNestCore
#if canImport(RasterNestRender)
import CoreGraphics
import RasterNestRender
#endif

@main
struct RNest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rnest",
        abstract: "RasterNest: capture, annotate and share screenshots from the command line.",
        version: RasterNestInfo.version,
        subcommands: [Capture.self, OCR.self, Export.self, Edit.self, Displays.self, Windows.self, Backends.self],
        defaultSubcommand: Capture.self
    )
}

// MARK: - capture

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Take a screenshot. With no options, select an area or window interactively.",
        discussion: """
        Examples:
          rnest capture                       pick an area or window
          rnest capture --region              drag out an area
          rnest capture --window              click a window
          rnest capture --fullscreen -c       whole main display, copied to the clipboard
          rnest capture --rect 0,0,800,600    exact rectangle (points, top-left origin)
          rnest capture --region --text       grab the text in an area (OCR)
          rnest capture -o - > shot.png       write PNG to stdout
        """
    )

    @Flag(name: .long, help: "Drag out an area to capture.")
    var region = false

    @Flag(name: .long, help: "Click a window to capture.")
    var window = false

    @Flag(name: [.customShort("f"), .long], help: "Capture a whole display.")
    var fullscreen = false

    @Option(name: .long, help: "Display index for --fullscreen (see `rnest displays`).")
    var display: Int?

    @Option(name: .long, help: "Exact area in points: x,y,width,height (origin top-left of the main display).")
    var rect: String?

    @Option(name: .customLong("window-id"), help: "Capture a specific window (see `rnest windows`).")
    var windowID: UInt32?

    @Option(name: .shortAndLong, help: "Output file. Use - for stdout. Default: ~/Pictures/RasterNest/<timestamp>.png")
    var output: String?

    @Flag(name: [.customShort("c"), .long], help: "Copy the result to the clipboard.")
    var clipboard = false

    @Flag(name: .long, help: "Recognize text in the capture and print it instead of saving an image.")
    var text = false

    @Option(name: .long, help: "Seconds to wait before capturing.")
    var delay: Int = 0

    @Flag(name: [.customShort("e"), .long], help: "Open the capture in the RasterNest editor (macOS).")
    var edit = false

    @Option(name: .long, help: "Force a capture backend (Linux: grim, gnome-screenshot, spectacle, maim, scrot, import).")
    var backend: String?

    @Flag(name: .shortAndLong, help: "Only print errors.")
    var quiet = false

    func validate() throws {
        let modes = [region, window, fullscreen, rect != nil, windowID != nil].filter { $0 }.count
        if modes > 1 { throw ValidationError("Choose only one of --region, --window, --fullscreen, --rect, --window-id.") }
        if display != nil && !fullscreen { throw ValidationError("--display requires --fullscreen.") }
        if delay < 0 { throw ValidationError("--delay must be zero or more.") }
    }

    func run() async throws {
        let target: CaptureTarget
        if region { target = .interactiveRegion }
        else if window { target = .interactiveWindow }
        else if fullscreen { target = .fullScreen(display: display) }
        else if let rect { target = .rect(try parseRect(rect)) }
        else if let windowID { target = .window(windowID) }
        else { target = .interactive }

        if delay > 0 {
            if !quiet { printErr("Capturing in \(delay)s…") }
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }

        let capturer = try Capturers.make(backend: backend)
        let result = try await capturer.capture(target)

        if text {
            let recognized = try await TextRecognition.recognize(imageData: result.png)
            print(recognized)
            if clipboard { try Clipboard.copyText(recognized) }
            return
        }

        if clipboard { try Clipboard.copyPNG(result.png) }

        if output == "-" {
            FileHandle.standardOutput.write(result.png)
            return
        }

        // With only --clipboard there's nothing to save unless asked.
        guard output != nil || !clipboard || edit else {
            if !quiet { printErr("Copied to clipboard.") }
            return
        }

        let url = try writeOutput(result.png)
        if !quiet { print(url.path) }
        if edit { try openInEditor(url) }
    }

    private func writeOutput(_ png: Data) throws -> URL {
        let url: URL
        if let output {
            url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        } else {
            url = CaptureNaming.defaultCaptureFolder()
                .appendingPathComponent(CaptureNaming.timestampedName() + ".png")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - ocr

struct OCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr",
        abstract: "Print the text found in an image (Vision on macOS, tesseract on Linux)."
    )

    @Argument(help: "Image file, or - to read from stdin.")
    var image: String

    @Flag(name: [.customShort("c"), .long], help: "Also copy the text to the clipboard.")
    var clipboard = false

    func run() async throws {
        let data = image == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (image as NSString).expandingTildeInPath))
        let text = try await TextRecognition.recognize(imageData: data)
        print(text)
        if clipboard { try Clipboard.copyText(text) }
    }
}

// MARK: - export

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Flatten a .rasternest document (or convert an image) to PNG or JPEG.",
        discussion: "Example: rnest export notes.rasternest --format png -o notes.png"
    )

    @Argument(help: "A .rasternest document or an image file.")
    var input: String

    @Option(name: .long, help: "Output format: png or jpg. Default: from --output's extension, else png.")
    var format: String?

    @Option(name: .shortAndLong, help: "Output file. Use - for stdout. Default: next to the input.")
    var output: String?

    @Option(name: .long, help: "JPEG quality, 0–100.")
    var quality: Int = 90

    @Flag(name: [.customShort("c"), .long], help: "Also copy the exported image to the clipboard.")
    var clipboard = false

    func run() async throws {
        #if canImport(RasterNestRender)
        let inURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let fmt: ExportFormat
        if let format {
            guard let f = ExportFormat(fileExtension: format) else { throw ValidationError("Unknown format `\(format)`. Use png or jpg.") }
            fmt = f
        } else if let output, output != "-", let f = ExportFormat(fileExtension: (output as NSString).pathExtension) {
            fmt = f
        } else {
            fmt = .png
        }

        let image: CGImage, scale: CGFloat
        if inURL.pathExtension.lowercased() == NestDocument.fileExtension {
            let (doc, base) = try ImageCodec.loadDocument(inURL)
            let renderer = AnnotationRenderer(unit: doc.pixelScale)
            guard let flat = renderer.flatten(image: base, annotations: doc.annotations) else {
                throw CaptureFailure.backendFailed("Rendering failed.")
            }
            image = flat
            scale = doc.pixelScale
        } else {
            guard let loaded = ImageCodec.load(inURL) else { throw ValidationError("Could not read \(input).") }
            (image, scale) = loaded
        }

        guard let data = ImageCodec.encode(image, format: fmt, scale: scale, quality: CGFloat(quality) / 100) else {
            throw CaptureFailure.backendFailed("Encoding failed.")
        }
        if clipboard { try Clipboard.copyPNG(fmt == .png ? data : ImageCodec.encode(image, format: .png, scale: scale) ?? data) }
        if output == "-" {
            FileHandle.standardOutput.write(data)
            return
        }
        let outURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? inURL.deletingPathExtension().appendingPathExtension(fmt.rawValue)
        try data.write(to: outURL, options: .atomic)
        print(outURL.path)
        #else
        throw CaptureFailure.unsupported("`rnest export` currently needs macOS; Linux rendering is on the roadmap.")
        #endif
    }
}

// MARK: - edit

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open an image or .rasternest document in the RasterNest editor (macOS).")

    @Argument(help: "File to open.")
    var file: String

    func run() async throws {
        try openInEditor(URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
    }
}

// MARK: - displays / windows / backends

struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List displays (use the index with --fullscreen --display).")

    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await Capturers.make().displays()
        if json { return try printJSON(list) }
        for d in list {
            print("\(d.index)\t\(Int(d.width))×\(Int(d.height)) @\(fmt(d.scale))x at \(Int(d.x)),\(Int(d.y))\(d.isMain ? "\tmain" : "")\t\(d.name)")
        }
    }
}

struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List on-screen windows (use the id with --window-id).")

    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await Capturers.make().windows()
        if json { return try printJSON(list) }
        for w in list {
            let title = w.title.isEmpty ? "" : " — \(w.title)"
            print("\(w.id)\t\(Int(w.width))×\(Int(w.height))\t\(w.owner)\(title)")
        }
    }
}

struct Backends: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show which capture backends are available on this machine.")

    func run() async throws {
        let list = Capturers.availableBackends()
        if list.isEmpty {
            printErr("No capture backend found.")
            throw ExitCode.failure
        }
        for (i, b) in list.enumerated() { print(i == 0 ? "\(b)\t(default)" : b) }
    }
}

// MARK: - helpers

func parseRect(_ s: String) throws -> CGRect {
    let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3], w > 0, h > 0 else {
        throw ValidationError("--rect must look like x,y,width,height (e.g. 0,0,800,600).")
    }
    return CGRect(x: x, y: y, width: w, height: h)
}

func openInEditor(_ url: URL) throws {
    #if os(macOS)
    let result = try Shell.run("/usr/bin/open", ["-b", RasterNestInfo.bundleIdentifier, url.path])
    if result.status != 0 {
        throw CaptureFailure.notFound("Couldn't open RasterNest.app. Install it with `brew install --cask rasternest`.")
    }
    #else
    throw CaptureFailure.unsupported("The RasterNest editor is macOS-only for now.")
    #endif
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try enc.encode(value), as: UTF8.self))
}

private func fmt(_ d: Double) -> String {
    d.rounded() == d ? String(Int(d)) : String(format: "%.1f", d)
}
