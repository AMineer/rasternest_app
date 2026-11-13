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
    RasterNest captures and annotates screenshots for documentation. Typical flow: `capture` (a window by app name \
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
