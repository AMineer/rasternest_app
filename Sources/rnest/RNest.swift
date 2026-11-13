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
        subcommands: [Capture.self, OCR.self, Annotate.self, Export.self, GuideCommand.self, MCPCommand.self, Edit.self,
                      Displays.self, Windows.self, Backends.self],
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

    @Flag(name: .long, help: "Print lines and words with their positions (image pixels, origin top-left) as JSON.")
    var json = false

    @Option(name: .long, help: "Print only the box of this text as JSON (best match first; see --all).")
    var find: String?

    @Flag(name: .long, help: "With --find, print every match instead of the best one.")
    var all = false

    func run() async throws {
        let data = image == "-"
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (image as NSString).expandingTildeInPath))
        let pngData = try AgentOps.pngData(data, name: image)
        let result = try await TextRecognition.analyze(imageData: pngData)
        if let find {
            let boxes = TextMatcher.matches(of: find, in: result.lines)
            guard !boxes.isEmpty else {
                printErr("\"\(find)\" not found.")
                throw ExitCode.failure
            }
            return try printJSON(all ? AnyEncodable(boxes) : AnyEncodable(boxes[0]))
        }
        if json { return try printJSON(result) }
        print(result.text)
        if clipboard { try Clipboard.copyText(result.text) }
    }
}

// MARK: - export

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Flatten captures to PNG/JPEG, combine them into a PDF, or turn a recording into a GIF.",
        discussion: """
        Examples:
          rnest export notes.rasternest --format png -o notes.png
          rnest export step1.rasternest step2.rasternest step3.png --format pdf -o guide.pdf --captions
          rnest export demo.mp4 --format gif --width 640 --fps 12
        """
    )

    @Argument(help: "A .rasternest document, an image, or a recording (.mp4/.mov). Several files for --format pdf.")
    var inputs: [String]

    @Option(name: .long, help: "Output format: png, jpg or pdf (gif for recordings). Default: from --output's extension, else png.")
    var format: String?

    @Option(name: .customLong("page-size"), help: "PDF page size: fit (each page matches its image), letter or a4.")
    var pageSize: String = "fit"

    @Flag(name: .long, help: "PDF: print each file's name under its image.")
    var captions = false

    @Option(name: .shortAndLong, help: "Output file. Use - for stdout. Default: next to the input.")
    var output: String?

    @Option(name: .long, help: "JPEG quality, 0–100.")
    var quality: Int = 90

    @Flag(name: [.customShort("c"), .long], help: "Also copy the exported image to the clipboard.")
    var clipboard = false

    @Option(name: .long, help: "GIF width in pixels (recordings only). 0 keeps the original width.")
    var width: Int = 800

    @Option(name: .long, help: "GIF frame rate (recordings only).")
    var fps: Double = 12

    func validate() throws {
        if inputs.isEmpty { throw ValidationError("Give at least one file to export.") }
        if inputs.count > 1 && !wantsPDF { throw ValidationError("Several files can only be exported together as --format pdf.") }
    }

    private var wantsPDF: Bool {
        format?.lowercased() == "pdf" || (output.map { ($0 as NSString).pathExtension.lowercased() == "pdf" } ?? false)
    }

    func run() async throws {
        if let url = try await perform() { print(url.path) }
    }

    /// Does the export and returns the file written (nil when writing to stdout).
    func perform() async throws -> URL? {
        #if canImport(RasterNestRender)
        let input = inputs[0]
        let inURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        if wantsPDF {
            guard let size = PDFComposer.PageSize(rawValue: pageSize.lowercased()) else {
                throw ValidationError("--page-size must be fit, letter or a4.")
            }
            guard output != "-" else { throw ValidationError("PDF export needs an output file, not stdout.") }
            var pages: [PDFComposer.Page] = []
            for path in inputs {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let (image, scale) = try Self.flattened(url)
                pages.append(PDFComposer.Page(image: image, scale: scale,
                                              caption: captions ? url.deletingPathExtension().lastPathComponent : nil))
            }
            let outURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? inURL.deletingPathExtension().appendingPathExtension("pdf")
            try PDFComposer.write(pages, to: outURL, pageSize: size, title: outURL.deletingPathExtension().lastPathComponent)
            return outURL
        }
        if ["mp4", "mov", "m4v"].contains(inURL.pathExtension.lowercased()) {
            if let format, format.lowercased() != "gif" { throw ValidationError("Recordings can only be exported as gif.") }
            guard output != "-" else { throw ValidationError("GIF export needs an output file, not stdout.") }
            let outURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? inURL.deletingPathExtension().appendingPathExtension("gif")
            try await GIFEncoder.convert(video: inURL, to: outURL,
                                         options: GIFEncoder.Options(fps: fps, maxWidth: width == 0 ? nil : width))
            return outURL
        }
        let fmt: ExportFormat
        if let format {
            guard let f = ExportFormat(fileExtension: format) else { throw ValidationError("Unknown format `\(format)`. Use png or jpg.") }
            fmt = f
        } else if let output, output != "-", let f = ExportFormat(fileExtension: (output as NSString).pathExtension) {
            fmt = f
        } else {
            fmt = .png
        }

        let (image, scale) = try Self.flattened(inURL)

        guard let data = ImageCodec.encode(image, format: fmt, scale: scale, quality: CGFloat(quality) / 100) else {
            throw CaptureFailure.backendFailed("Encoding failed.")
        }
        if clipboard { try Clipboard.copyPNG(fmt == .png ? data : ImageCodec.encode(image, format: .png, scale: scale) ?? data) }
        if output == "-" {
            FileHandle.standardOutput.write(data)
            return nil
        }
        let outURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? inURL.deletingPathExtension().appendingPathExtension(fmt.rawValue)
        try data.write(to: outURL, options: .atomic)
        return outURL
        #else
        throw CaptureFailure.unsupported("`rnest export` currently needs macOS; Linux rendering is on the roadmap.")
        #endif
    }

    #if canImport(RasterNestRender)
    /// A document with its annotations and frame burned in, or a plain image as-is.
    static func flattened(_ url: URL) throws -> (CGImage, CGFloat) {
        if url.pathExtension.lowercased() == NestDocument.fileExtension {
            let (doc, base) = try ImageCodec.loadDocument(url)
            guard let flat = AnnotationRenderer(unit: doc.pixelScale)
                .flatten(image: base, annotations: doc.annotations, effects: doc.effects ?? .none) else {
                throw CaptureFailure.backendFailed("Rendering \(url.lastPathComponent) failed.")
            }
            return (flat, doc.pixelScale)
        }
        guard let loaded = ImageCodec.load(url) else { throw ValidationError("Could not read \(url.path).") }
        return loaded
    }
    #endif
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
        throw CaptureFailure.notFound("Couldn't open RasterNest.app. Install it with `brew trust amineer/tap && brew install --cask amineer/tap/rasternest`.")
    }
    #else
    throw CaptureFailure.unsupported("The RasterNest editor is macOS-only for now.")
    #endif
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try enc.encode(value), as: UTF8.self))
}

private func fmt(_ d: Double) -> String {
    d.rounded() == d ? String(Int(d)) : String(format: "%.1f", d)
}
