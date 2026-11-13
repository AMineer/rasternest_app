import Foundation

/// A rebuildable documentation guide: a list of steps, each a capture plus markup.
/// `rnest guide run` re-captures every step, so when the UI changes the screenshots
/// regenerate instead of being redrawn by hand.
///
/// ```json
/// {
///   "title": "Turn on dark mode",
///   "output": "img",
///   "frame": "docs",
///   "markdown": "dark-mode.md",
///   "steps": [
///     {
///       "name": "appearance",
///       "caption": "Open Appearance in System Settings.",
///       "before": "open 'x-apple.systempreferences:com.apple.Appearance-Settings.extension'",
///       "wait": 2,
///       "capture": { "window": "System Settings" },
///       "annotations": [ { "type": "box", "around": { "text": "Dark" } } ]
///     }
///   ]
/// }
/// ```
public struct Guide: Codable, Equatable, Sendable {
    public var title: String
    /// Folder for the images, relative to the guide file. Default: `<guide name>-images`.
    public var output: String?
    /// Frame for every step unless the step sets its own: none or docs.
    public var frame: String?
    /// Markdown file to write (relative to the guide file). Default: `<guide name>.md`. Use "" to skip.
    public var markdown: String?
    /// Optional PDF of all steps (relative to the guide file).
    public var pdf: String?
    public var steps: [Step]

    public init(title: String, output: String? = nil, frame: String? = nil, markdown: String? = nil,
                pdf: String? = nil, steps: [Step]) {
        self.title = title; self.output = output; self.frame = frame; self.markdown = markdown; self.pdf = pdf; self.steps = steps
    }

    public struct Step: Codable, Equatable, Sendable {
        /// Short identifier used in file names. Default: step number.
        public var name: String?
        public var caption: String?
        /// Shell command run before capturing (e.g. open an app or URL).
        public var before: String?
        /// Seconds to wait after `before` and before capturing.
        public var wait: Double?
        public var capture: CaptureSpec
        public var frame: String?
        public var annotations: [AnnotationSpec.Item]?

        public init(name: String? = nil, caption: String? = nil, before: String? = nil, wait: Double? = nil,
                    capture: CaptureSpec, frame: String? = nil, annotations: [AnnotationSpec.Item]? = nil) {
            self.name = name; self.caption = caption; self.before = before; self.wait = wait
            self.capture = capture; self.frame = frame; self.annotations = annotations
        }
    }

    /// What to capture. Exactly one field is used, in this order:
    /// file, window/app, rect, display/fullscreen.
    public struct CaptureSpec: Codable, Equatable, Sendable {
        /// An existing image to annotate instead of capturing (relative to the guide file).
        public var file: String?
        /// Front-most window whose app name or title contains this text.
        public var window: String?
        /// Front-most window of an app with this name.
        public var app: String?
        /// Narrows `app` to a window whose title contains this.
        public var title: String?
        /// [x, y, width, height] in screen points, origin top-left of the main display.
        public var rect: [Double]?
        public var fullscreen: Bool?
        public var display: Int?

        public init(file: String? = nil, window: String? = nil, app: String? = nil, title: String? = nil,
                    rect: [Double]? = nil, fullscreen: Bool? = nil, display: Int? = nil) {
            self.file = file; self.window = window; self.app = app; self.title = title
            self.rect = rect; self.fullscreen = fullscreen; self.display = display
        }
    }

    /// File-name stem for step `index` (0-based): `01-open-settings`.
    public func stem(for index: Int) -> String {
        let n = String(format: "%02d", index + 1)
        guard let name = steps[index].name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return n }
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? n : "\(n)-\(collapsed)"
    }

    /// Markdown for the guide, with image paths relative to the markdown file.
    public func markdown(imagePaths: [String]) -> String {
        var md = "# \(title)\n"
        for (i, step) in steps.enumerated() {
            md += "\n## Step \(i + 1)"
            if let caption = step.caption, !caption.isEmpty { md += "\n\n\(caption)" }
            if imagePaths.indices.contains(i) {
                let alt = (step.caption ?? "Step \(i + 1)").replacingOccurrences(of: "]", with: "")
                md += "\n\n![\(alt)](\(imagePaths[i]))"
            }
            md += "\n"
        }
        return md
    }

    public static func decoded(from data: Data) throws -> Guide {
        try JSONDecoder().decode(Guide.self, from: data)
    }

    /// A starter guide written by `rnest guide init`.
    public static let example = Guide(
        title: "Example guide",
        frame: "docs",
        steps: [
            Step(name: "desktop", caption: "This is the whole screen. Replace `capture` with a window, e.g. { \"app\": \"Safari\" }.",
                 capture: CaptureSpec(fullscreen: true),
                 annotations: [AnnotationSpec.Item(type: "redact", pattern: "email")]),
            Step(name: "finder", caption: "Finder, with step 1 on its first menu.",
                 before: "open -a Finder", wait: 1.5,
                 capture: CaptureSpec(app: "Finder"),
                 annotations: [AnnotationSpec.Item(type: "step", at: AnnotationSpec.Anchor(text: "Recents"), label: "Start here")]),
        ]
    )
}
