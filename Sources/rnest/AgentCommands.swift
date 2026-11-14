import ArgumentParser
import Foundation
import RasterNestCapture
import RasterNestCore
#if canImport(RasterNestRender)
import CoreGraphics
import RasterNestRender
#endif

// MARK: - annotate

struct Annotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add markup to an image from a spec or flags, placing it by the text on screen.",
        discussion: """
        Anchors are found with OCR, so you name what's on screen instead of measuring pixels.

        Examples:
          rnest annotate shot.png --step Save --step Allow --redact email
          rnest annotate shot.png --box "Advanced" --arrow "Apply" --frame docs -o step3.png
          rnest annotate shot.png --spec markup.json -o shot.rasternest
          echo '{"annotations":[{"type":"step","at":{"text":"Save"}}]}' | rnest annotate shot.png --spec -

        Spec format (pixels, origin top-left):
          { "frame": "docs", "annotations": [
              { "type": "step",   "at": { "text": "Save" }, "label": "Click Save" },
              { "type": "arrow",  "to": { "text": "Allow" } },
              { "type": "box",    "around": { "rect": [40, 80, 300, 60] } },
              { "type": "text",   "text": "New!", "at": { "x": 500, "y": 120 } },
              { "type": "redact", "pattern": "email" } ] }
        Types: step, arrow, line, box, ellipse, highlight, text, pixelate, redact, spotlight, magnify.
        Redaction patterns: email, phone, ipv4, url, card, token (or "regex" / "match").
        """
    )

    @Argument(help: "Image or .rasternest document to annotate.")
    var input: String

    @Option(name: .long, help: "Annotation spec JSON file, or - for stdin.")
    var spec: String?

    @Option(name: .long, help: "Numbered step next to this text. Repeat for more steps.")
    var step: [String] = []

    @Option(name: .long, help: "Rectangle around this text.")
    var box: [String] = []

    @Option(name: .long, help: "Arrow pointing at this text.")
    var arrow: [String] = []

    @Option(name: .long, help: "Highlight this text.")
    var highlight: [String] = []

    @Option(name: .long, help: "Pixelate matches: email, phone, ipv4, url, card, token, or any literal text.")
    var redact: [String] = []

    @Option(name: .long, help: "Frame: none or docs.")
    var frame: String?

    @Option(name: .long, help: "Default color (name or #RRGGBB).")
    var color: String?

    @Option(name: .shortAndLong, help: "Output: .png, .jpg or .rasternest. Default: <input>-annotated.png next to the input.")
    var output: String?

    @Flag(name: [.customShort("e"), .long], help: "Open the result in the RasterNest editor (macOS).")
    var edit = false

    func run() async throws {
        let inURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        var annotationSpec = AnnotationSpec(frame: frame, color: color, annotations: [])
        if let spec {
            let data = spec == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: (spec as NSString).expandingTildeInPath))
            do {
                let parsed = try JSONDecoder().decode(AnnotationSpec.self, from: data)
                annotationSpec.annotations = parsed.annotations
                annotationSpec.frame = frame ?? parsed.frame
                annotationSpec.color = color ?? parsed.color
            } catch {
                throw ValidationError("Couldn't read the spec: \(error)")
            }
        }
        typealias Item = AnnotationSpec.Item
        typealias Anchor = AnnotationSpec.Anchor
        annotationSpec.annotations += step.map { Item(type: "step", at: Anchor(text: $0)) }
        annotationSpec.annotations += box.map { Item(type: "box", around: Anchor(text: $0)) }
        annotationSpec.annotations += arrow.map { Item(type: "arrow", to: Anchor(text: $0)) }
        annotationSpec.annotations += highlight.map { Item(type: "highlight", around: Anchor(text: $0)) }
        annotationSpec.annotations += redact.map {
            RedactionPattern(rawValue: $0.lowercased()) != nil ? Item(type: "redact", pattern: $0) : Item(type: "redact", match: $0)
        }
        if annotationSpec.annotations.isEmpty && annotationSpec.frame == nil {
            throw ValidationError("Nothing to add. Give --spec, or flags like --step, --box, --arrow, --redact or --frame.")
        }

        var doc = try AgentOps.loadDocument(inURL)
        try await AgentOps.apply(annotationSpec, to: &doc)

        let outURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? inURL.deletingLastPathComponent()
                .appendingPathComponent(inURL.deletingPathExtension().lastPathComponent + "-annotated.png")
        try AgentOps.write(doc, to: outURL)
        print(outURL.path)
        if edit { try openInEditor(outURL) }
    }
}

// MARK: - guide

struct GuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Build step-by-step docs from a guide file, and rebuild every screenshot when the UI changes.",
        subcommands: [Run.self, Init.self],
        defaultSubcommand: Run.self
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Capture and annotate every step, then write the images, Markdown and (optionally) a PDF.",
            discussion: """
            Example:
              rnest guide init dark-mode.json     write a starter guide
              rnest guide run dark-mode.json      (re)build all steps
              rnest guide run dark-mode.json --step appearance
            """
        )

        @Argument(help: "Guide file (JSON).")
        var file: String

        @Option(name: .long, help: "Only rebuild this step (name or number). Repeat for more.")
        var step: [String] = []

        func run() async throws {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let report = try await AgentOps.runGuide(at: url, only: Set(step)) { printErr($0) }
            for doc in report.images { print(doc.path) }
            if let md = report.markdown { print(md.path) }
            if let pdf = report.pdf { print(pdf.path) }
        }
    }

    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a starter guide file.")

        @Argument(help: "Where to write it.")
        var file: String = "guide.json"

        @Flag(name: .long, help: "Overwrite an existing file.")
        var force = false

        func run() async throws {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) && !force {
                throw ValidationError("\(url.path) already exists. Use --force to overwrite it.")
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(Guide.example).write(to: url, options: .atomic)
            print(url.path)
        }
    }
}

// MARK: - mcp

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a Model Context Protocol server on stdio so AI agents can capture, read and annotate screenshots.",
        discussion: """
        Claude Code:     claude mcp add rasternest -- rnest mcp
        Claude Desktop:  add to claude_desktop_config.json:
                         { "mcpServers": { "rasternest": { "command": "rnest", "args": ["mcp"] } } }

        On macOS, Screen Recording permission belongs to the app that starts the server
        (your terminal or Claude). Captures are saved in ~/Pictures/RasterNest/agent unless a path is given.
        """
    )

    func run() async throws {
        let server = MCPServer(name: "rasternest", version: RasterNestInfo.version,
                               instructions: MCPTools.instructions, tools: MCPTools.all)
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            if let response = await server.handle(line: line) {
                print(response)
                fflush(stdout)
            }
        }
    }
}

enum MCPTools {
    static let instructions = """
    RasterNest captures, records and annotates screenshots for documentation. Use `record` for a GIF of something happening. Typical screenshot flow: `capture` (a window by app name \
    is usually best), look at the preview, call `ocr` to see what text is where, then `annotate` using text anchors \
    such as {"text": "Save"} rather than pixel coordinates. All coordinates are full-size image pixels with the origin \
    at the top-left; previews may be scaled down. Redact personal data (pattern "email", "phone", "token") before sharing. \
    For multi-step docs that should be rebuilt when the UI changes, write a guide file and call `run_guide`.
    """

    static var agentFolder: URL {
        CaptureNaming.defaultCaptureFolder().appendingPathComponent("agent", isDirectory: true)
    }

    static func outputURL(_ path: String?, ext: String) -> URL {
        if let path, !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return agentFolder.appendingPathComponent(CaptureNaming.timestampedName() + "." + ext)
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(value), as: UTF8.self)) ?? "{}"
    }

    /// File info plus, on macOS, a scaled preview the model can look at.
    static func describe(_ url: URL, doc: NestDocument, includeImage: Bool) -> [MCPContent] {
        let info = PNGInfo(doc.imagePNG)
        var meta: [String: JSONValue] = [
            "path": .string(url.path),
            "scale": .number(Double(doc.pixelScale)),
            "annotations": .number(Double(doc.annotations.count)),
        ]
        if let info { meta["width"] = .number(Double(info.width)); meta["height"] = .number(Double(info.height)) }
        var out: [MCPContent] = [.text(json(JSONValue.object(meta)))]
        #if canImport(RasterNestRender)
        if includeImage, let image = AgentOps.render(doc), let jpeg = AgentOps.preview(image) {
            if image.width > 1568 || image.height > 1568 {
                out[0] = .text(json(JSONValue.object(meta)) + "\nPreview scaled down; coordinates refer to the full-size image.")
            }
            out.append(.image(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg"))
        }
        #endif
        return out
    }

    static func string(_ args: JSONValue, _ key: String) -> String? {
        guard let s = args[key]?.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    static let anchorSchema: JSONValue = [
        "type": "object",
        "description": "Where to place it: {\"text\": \"Save\"} (found by OCR), {\"x\":…, \"y\":…}, or {\"rect\": [x, y, w, h]} in image pixels.",
        "properties": [
            "text": ["type": "string"], "occurrence": ["type": "integer"],
            "x": ["type": "number"], "y": ["type": "number"],
            "rect": ["type": "array", "items": ["type": "number"]],
        ],
    ]

    static var all: [MCPTool] {
        [
            MCPTool(
                name: "capture",
                description: "Take a screenshot. Give `app` (and optionally `title`) to capture that app's front window, `window_id` from list_windows, `rect` in screen points, or nothing for the whole main display. `interactive: true` lets the user pick. Returns the saved PNG path, its size and a preview.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "App name, e.g. Safari or System Settings."],
                        "title": ["type": "string", "description": "Part of the window title (with app)."],
                        "window_id": ["type": "integer"],
                        "rect": ["type": "array", "items": ["type": "number"], "description": "[x, y, width, height] in screen points."],
                        "display": ["type": "integer", "description": "Display index for a full-screen capture."],
                        "interactive": ["type": "boolean", "description": "Let the user select an area or window."],
                        "delay": ["type": "number", "description": "Seconds to wait first."],
                        "output": ["type": "string", "description": "PNG path. Default: ~/Pictures/RasterNest/agent/<timestamp>.png"],
                        "include_image": ["type": "boolean", "description": "Return a preview image (default true)."],
                    ],
                ],
                handler: { args in
                    if let delay = args["delay"]?.double, delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                    var shot: AgentOps.Captured
                    if let id = args["window_id"]?.int {
                        let r = try await Capturers.make().capture(.window(UInt32(id)))
                        shot = AgentOps.Captured(png: r.png, scale: r.pixelScale)
                    } else {
                        let spec = Guide.CaptureSpec(app: string(args, "app"), title: string(args, "title"),
                                                     rect: args["rect"]?.array?.compactMap(\.double),
                                                     display: args["display"]?.int)
                        shot = try await AgentOps.capture(spec, relativeTo: nil, interactive: args["interactive"]?.bool ?? false)
                    }
                    let url = outputURL(string(args, "output"), ext: "png")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try shot.png.write(to: url, options: .atomic)
                    let doc = NestDocument(imagePNG: shot.png, pixelScale: CGFloat(shot.scale), annotations: [])
                    return describe(url, doc: doc, includeImage: args["include_image"]?.bool ?? true)
                }
            ),
            MCPTool(
                name: "record",
                description: "Record the screen to a GIF (and/or MP4) for docs or demos (macOS). Target `app` (front window of that app), `window_id`, `rect` (screen points) or a whole display. Recording lasts `duration` seconds, or, with `during`, until that shell command finishes. Use `during` to drive the demo (e.g. an AppleScript or `open` command); otherwise the user acts while it records. Returns file paths and a preview frame.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "Record this app's front window."],
                        "title": ["type": "string", "description": "With app: part of the window title."],
                        "window_id": ["type": "integer"],
                        "rect": ["type": "array", "items": ["type": "number"], "description": "[x, y, width, height] in screen points."],
                        "display": ["type": "integer"],
                        "duration": ["type": "number", "description": "Seconds (default 5 when `during` is not given; max 120)."],
                        "during": ["type": "string", "description": "Shell command run while recording; recording stops when it exits unless duration is set."],
                        "delay": ["type": "number", "description": "Seconds to wait before starting."],
                        "format": ["type": "string", "description": "gif (default), mp4, or both."],
                        "output": ["type": "string", "description": "Output path (.gif or .mp4). Default: ~/Pictures/RasterNest/agent/<timestamp>."],
                        "gif_width": ["type": "integer", "description": "GIF width in pixels (default 800; 0 = full size)."],
                        "gif_fps": ["type": "number", "description": "GIF frame rate (default 12)."],
                        "cursor": ["type": "boolean", "description": "Show the pointer (default true)."],
                        "include_image": ["type": "boolean", "description": "Return a preview frame (default true)."],
                    ],
                ],
                handler: { args in
                    var req = AgentOps.RecordRequest()
                    req.windowID = args["window_id"]?.int.map(UInt32.init)
                    req.capture = Guide.CaptureSpec(app: string(args, "app"), title: string(args, "title"),
                                                    rect: args["rect"]?.array?.compactMap(\.double), display: args["display"]?.int)
                    req.during = string(args, "during")
                    req.duration = min(120, args["duration"]?.double ?? (req.during == nil ? 5 : 0))
                    if req.duration == 0 { req.duration = nil }
                    req.maxDuration = 120
                    req.cursor = args["cursor"]?.bool ?? true
                    req.gifWidth = args["gif_width"]?.int ?? 800
                    req.gifFPS = args["gif_fps"]?.double ?? 12
                    let format = (string(args, "format") ?? "gif").lowercased()
                    let base = string(args, "output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    let stem = (base ?? outputURL(nil, ext: "gif")).deletingPathExtension()
                    switch base?.pathExtension.lowercased() ?? format {
                    case "mp4", "mov": req.mp4 = base ?? stem.appendingPathExtension("mp4")
                    case "both": req.mp4 = stem.appendingPathExtension("mp4"); req.gif = stem.appendingPathExtension("gif")
                    default: req.gif = base ?? stem.appendingPathExtension("gif")
                    }
                    if format == "both" && base != nil {
                        req.mp4 = stem.appendingPathExtension("mp4"); req.gif = stem.appendingPathExtension("gif")
                    }
                    if let delay = args["delay"]?.double, delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                    let result = try await AgentOps.record(req) { printErr($0) }
                    var meta: [String: JSONValue] = [
                        "seconds": .number((result.seconds * 10).rounded() / 10),
                        "width": .number(Double(result.pixelSize.width)), "height": .number(Double(result.pixelSize.height)),
                    ]
                    if let gif = result.gif {
                        meta["gif"] = .string(gif.path)
                        let size = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
                        meta["gif_bytes"] = .number(Double(size))
                    }
                    if let mp4 = result.mp4 { meta["mp4"] = .string(mp4.path) }
                    var out: [MCPContent] = [.text(json(JSONValue.object(meta)))]
                    #if canImport(RasterNestRender)
                    let video = result.mp4
                    if args["include_image"]?.bool ?? true {
                        if let video, let jpeg = await AgentOps.videoPreview(video) {
                            out.append(.image(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg"))
                        } else if let gif = result.gif, let (img, _) = ImageCodec.load(gif), let jpeg = AgentOps.preview(img, maxSide: 1200) {
                            out.append(.image(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg"))
                        }
                    }
                    #endif
                    return out
                }
            ),
            MCPTool(
                name: "ocr",
                description: "Read the text in an image with positions. Returns lines with boxes {x, y, width, height} in image pixels (origin top-left). Use `find` to get just the box of some text.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "PNG/JPEG or .rasternest file."],
                        "find": ["type": "string", "description": "Only return where this text is."],
                        "words": ["type": "boolean", "description": "Include per-word boxes (default false)."],
                    ],
                    "required": ["path"],
                ],
                handler: { args in
                    guard let path = string(args, "path") else { throw ValidationError("`path` is required.") }
                    let doc = try AgentOps.loadDocument(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    var result = try await TextRecognition.analyze(imageData: doc.imagePNG)
                    if let find = string(args, "find") {
                        let boxes = TextMatcher.matches(of: find, in: result.lines)
                        return [.text(boxes.isEmpty ? "\"\(find)\" not found. Text present: \(result.lines.prefix(40).map(\.text))" : json(boxes))]
                    }
                    if !(args["words"]?.bool ?? false) {
                        for i in result.lines.indices { result.lines[i].words = [] }
                    }
                    return [.text(json(result))]
                }
            ),
            MCPTool(
                name: "annotate",
                description: """
                Add markup to an image and save it. Each annotation: {"type": step|arrow|line|box|ellipse|highlight|text|pixelate|redact|spotlight|magnify, …}. \
                step: {"at": anchor, "label"?}. arrow/line: {"to": anchor, "from"?: anchor, "label"?}. box/ellipse/highlight/pixelate/spotlight/magnify: {"around": anchor}. \
                text: {"text": "…", "at": anchor}. redact: {"pattern": email|phone|ipv4|url|card|token} or {"regex": "…"} or {"match": "literal"} or {"around": anchor}. \
                Optional on any: color (name or #RRGGBB), width, size, padding. Anchors: {"text": "Save"} is best. \
                Output .png/.jpg is flattened; .rasternest stays editable in the RasterNest app. Returns the path and a preview.
                """,
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "input": ["type": "string", "description": "Image or .rasternest file to annotate."],
                        "annotations": ["type": "array", "items": [
                            "type": "object",
                            "properties": [
                                "type": ["type": "string"], "at": anchorSchema, "around": anchorSchema, "to": anchorSchema, "from": anchorSchema,
                                "text": ["type": "string"], "label": ["type": "string"], "number": ["type": "integer"],
                                "pattern": ["type": "string"], "regex": ["type": "string"], "match": ["type": "string"],
                                "color": ["type": "string"], "width": ["type": "number"], "size": ["type": "number"],
                                "padding": ["type": "number"], "zoom": ["type": "number"],
                            ],
                            "required": ["type"],
                        ]],
                        "frame": ["type": "string", "description": "none or docs (padding, background, rounded corners, shadow)."],
                        "output": ["type": "string", "description": "Default: <input>-annotated.png next to the input."],
                        "also_save_editable": ["type": "boolean", "description": "Also write a .rasternest next to the output (default true)."],
                        "include_image": ["type": "boolean"],
                    ],
                    "required": ["input"],
                ],
                handler: { args in
                    guard let input = string(args, "input") else { throw ValidationError("`input` is required.") }
                    let inURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
                    let items = try (args["annotations"] ?? .array([])).decode([AnnotationSpec.Item].self)
                    let spec = AnnotationSpec(frame: string(args, "frame"), annotations: items)
                    var doc = try AgentOps.loadDocument(inURL)
                    try await AgentOps.apply(spec, to: &doc)
                    let outURL = string(args, "output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                        ?? inURL.deletingLastPathComponent()
                            .appendingPathComponent(inURL.deletingPathExtension().lastPathComponent + "-annotated.png")
                    try AgentOps.write(doc, to: outURL)
                    var out = describe(outURL, doc: doc, includeImage: args["include_image"]?.bool ?? true)
                    if (args["also_save_editable"]?.bool ?? true) && outURL.pathExtension.lowercased() != NestDocument.fileExtension {
                        let docURL = outURL.deletingPathExtension().appendingPathExtension(NestDocument.fileExtension)
                        try AgentOps.write(doc, to: docURL)
                        out.insert(.text("Editable copy: \(docURL.path)"), at: 1)
                    }
                    return out
                }
            ),
            MCPTool(
                name: "export",
                description: "Flatten .rasternest files to PNG/JPEG, combine several captures into one PDF, or convert an MP4 recording to GIF.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "inputs": ["type": "array", "items": ["type": "string"]],
                        "format": ["type": "string", "description": "png, jpg, pdf or gif."],
                        "output": ["type": "string"],
                        "page_size": ["type": "string", "description": "PDF: fit, letter or a4."],
                        "captions": ["type": "boolean", "description": "PDF: file name under each image."],
                    ],
                    "required": ["inputs"],
                ],
                handler: { args in
                    var argv = (args["inputs"]?.array ?? []).compactMap(\.string)
                    guard !argv.isEmpty else { throw ValidationError("`inputs` is required.") }
                    if let f = string(args, "format") { argv += ["--format", f] }
                    if let o = string(args, "output") { argv += ["--output", o] }
                    if let p = string(args, "page_size") { argv += ["--page-size", p] }
                    if args["captions"]?.bool == true { argv.append("--captions") }
                    let cmd = try Export.parse(argv)
                    guard let url = try await cmd.perform() else { throw ValidationError("Export needs an output file.") }
                    return [.text(url.path)]
                }
            ),
            MCPTool(
                name: "run_guide",
                description: "Build or rebuild a step-by-step guide from a guide JSON file: captures each step, applies its annotations, and writes images, Markdown and an optional PDF. Format: {\"title\", \"output\"?, \"frame\"?, \"markdown\"?, \"pdf\"?, \"steps\": [{\"name\", \"caption\", \"before\"? (shell command), \"wait\"? (s), \"capture\": {\"app\"|\"window\"|\"rect\"|\"fullscreen\"|\"file\"}, \"annotations\": [...]}]}.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "steps": ["type": "array", "items": ["type": "string"], "description": "Only rebuild these steps (names or numbers)."],
                    ],
                    "required": ["path"],
                ],
                handler: { args in
                    guard let path = string(args, "path") else { throw ValidationError("`path` is required.") }
                    let only = Set((args["steps"]?.array ?? []).compactMap { $0.string ?? $0.int.map(String.init) })
                    let report = try await AgentOps.runGuide(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                                                             only: only) { printErr($0) }
                    var lines = report.images.map(\.path)
                    if let md = report.markdown { lines.append("Markdown: \(md.path)") }
                    if let pdf = report.pdf { lines.append("PDF: \(pdf.path)") }
                    return [.text(lines.joined(separator: "\n"))]
                }
            ),
            MCPTool(
                name: "list_windows",
                description: "On-screen windows with id, app, title and frame (screen points).",
                inputSchema: ["type": "object", "properties": ["app": ["type": "string", "description": "Only this app."]]],
                handler: { args in
                    var list = try await Capturers.make().windows()
                    if let app = string(args, "app") {
                        list = list.filter { $0.owner.range(of: app, options: .caseInsensitive) != nil }
                    }
                    return [.text(json(list))]
                }
            ),
            MCPTool(
                name: "list_displays",
                description: "Displays with index, size, position and scale.",
                inputSchema: ["type": "object", "properties": [:]],
                handler: { _ in [.text(json(try await Capturers.make().displays()))] }
            ),
            MCPTool(
                name: "open_in_editor",
                description: "Open an image or .rasternest file in the RasterNest editor so the user can adjust it (macOS).",
                inputSchema: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
                handler: { args in
                    guard let path = string(args, "path") else { throw ValidationError("`path` is required.") }
                    try openInEditor(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    return [.text("Opened \(path) in RasterNest.")]
                }
            ),
        ]
    }
}

// MARK: - record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record the screen, a window or an area to MP4 and/or GIF (macOS).",
        discussion: """
        Stops after --duration, when the --run command finishes, or when you press Return or Ctrl-C.

        Examples:
          rnest record --app Safari --duration 8 -o demo.gif
          rnest record --rect 0,120,900,600 --duration 5 --gif          MP4 plus a GIF beside it
          rnest record --fullscreen                                      until Return / Ctrl-C
          rnest record --app Terminal --run './demo.sh' -o demo.gif      record while a script runs
        """
    )

    @Flag(name: [.customShort("f"), .long], help: "Record a whole display (default when no target is given).")
    var fullscreen = false

    @Option(name: .long, help: "Display index for --fullscreen (see `rnest displays`).")
    var display: Int?

    @Option(name: .long, help: "Area in points: x,y,width,height (origin top-left of the main display).")
    var rect: String?

    @Option(name: .customLong("window-id"), help: "Record one window (see `rnest windows`).")
    var windowID: UInt32?

    @Option(name: .long, help: "Record the front window of this app.")
    var app: String?

    @Option(name: .long, help: "With --app: a window whose title contains this.")
    var title: String?

    @Option(name: [.customShort("d"), .long], help: "Seconds to record.")
    var duration: Double?

    @Option(name: .customLong("run"), help: "Shell command to run once recording starts; recording stops when it exits (unless --duration is set).")
    var runCommand: String?

    @Option(name: .shortAndLong, help: "Output .mp4 or .gif. Default: ~/Pictures/RasterNest/<timestamp>.mp4")
    var output: String?

    @Flag(name: .long, help: "Also write a GIF next to the MP4.")
    var gif = false

    @Option(name: .customLong("gif-width"), help: "GIF width in pixels (0 = full size).")
    var gifWidth: Int = 800

    @Option(name: .customLong("gif-fps"), help: "GIF frame rate.")
    var gifFPS: Double = 12

    @Option(name: .long, help: "Video frame rate.")
    var fps: Int = 30

    @Option(name: .long, help: "Seconds to wait before recording.")
    var delay: Double = 0

    @Flag(name: .long, help: "Record system audio (MP4 only).")
    var audio = false

    @Flag(name: .long, help: "Record the microphone (macOS 15+, MP4 only).")
    var mic = false

    @Flag(name: .customLong("no-cursor"), help: "Hide the mouse pointer.")
    var noCursor = false

    @Flag(name: .shortAndLong, help: "Only print errors.")
    var quiet = false

    func validate() throws {
        let modes = [fullscreen, rect != nil, windowID != nil, app != nil].filter { $0 }.count
        if modes > 1 { throw ValidationError("Choose only one of --fullscreen, --rect, --window-id, --app.") }
        if title != nil && app == nil { throw ValidationError("--title needs --app.") }
        if let duration, duration <= 0 { throw ValidationError("--duration must be more than zero.") }
        if let output, !["mp4", "mov", "gif"].contains((output as NSString).pathExtension.lowercased()) {
            throw ValidationError("--output must end in .mp4 or .gif.")
        }
    }

    func run() async throws {
        var req = AgentOps.RecordRequest()
        req.windowID = windowID
        req.capture = Guide.CaptureSpec(app: app, title: title, rect: try rect.map { r in
            let c = try parseRect(r); return [Double(c.minX), Double(c.minY), Double(c.width), Double(c.height)]
        }, display: display)
        req.duration = duration
        req.during = runCommand
        req.fps = fps
        req.cursor = !noCursor
        req.systemAudio = audio
        req.microphone = mic
        req.gifWidth = gifWidth
        req.gifFPS = gifFPS

        let out = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? CaptureNaming.defaultCaptureFolder().appendingPathComponent(CaptureNaming.timestampedName() + ".mp4")
        if out.pathExtension.lowercased() == "gif" {
            req.gif = out
        } else {
            req.mp4 = out
            if gif { req.gif = out.deletingPathExtension().appendingPathExtension("gif") }
        }

        if delay > 0 {
            if !quiet { printErr("Recording in \(delay)s…") }
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        }

        // Stop on Ctrl-C or Return.
        let stop = StopFlag()
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { stop.set() }
        sigint.resume()
        if duration == nil && runCommand == nil && isatty(STDIN_FILENO) != 0 {
            Thread.detachNewThread { _ = readLine(); stop.set() }
        }
        if !quiet {
            printErr(duration.map { "Recording for \($0)s… (Ctrl-C to stop early)" }
                     ?? (runCommand != nil ? "Recording until the command finishes…" : "Recording… press Return or Ctrl-C to stop."))
        }

        let result = try await AgentOps.record(req, stop: stop) { if !quiet { printErr($0) } }
        sigint.cancel()
        if let mp4 = result.mp4 { print(mp4.path) }
        if let gif = result.gif { print(gif.path) }
    }
}
