using System.Text.Json;
using System.Text.Json.Nodes;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;

namespace RasterNest.Cli;

/// <summary>The MCP tools, with the same names and arguments as the Mac/Linux <c>rnest mcp</c>.</summary>
public static class McpTools
{
    public const string Instructions =
        "RasterNest captures, records and annotates screenshots for documentation. Use `record` for a GIF of something happening. Typical screenshot flow: `capture` (a window by app name " +
        "is usually best), look at the preview, call `ocr` to see what text is where, then `annotate` using text anchors " +
        "such as {\"text\": \"Save\"} rather than pixel coordinates. All coordinates are full-size image pixels with the origin " +
        "at the top-left; previews may be scaled down. Redact personal data (pattern \"email\", \"phone\", \"token\") before sharing. " +
        "For multi-step docs that should be rebuilt when the UI changes, write a guide file and call `run_guide`. " +
        "On Windows, `app` matches the process name (msedge, notepad, explorer) or the app's name, and screen rects are in pixels.";

    private static string AgentFolder => Path.Combine(CaptureNaming.DefaultCaptureFolder(), "agent");

    private static string OutputPath(string? path, string ext) =>
        !string.IsNullOrWhiteSpace(path) ? AgentOps.ExpandPath(path) : Path.Combine(AgentFolder, CaptureNaming.TimestampedName() + "." + ext);

    private static string Json(object value) => RasterNestJson.Serialize(value);

    private static string? S(JsonObject args, string key) => args.Str(key)?.Trim() is { Length: > 0 } s ? s : null;

    /// <summary>File info plus a scaled preview the model can look at.</summary>
    private static List<McpContent> Describe(string path, NestDocument doc, bool includeImage)
    {
        var info = PngInfo.Read(doc.ImagePng);
        var meta = new JsonObject { ["path"] = path, ["scale"] = doc.PixelScale, ["annotations"] = doc.Annotations.Count };
        if (info is { } i) { meta["width"] = i.Width; meta["height"] = i.Height; }
        var output = new List<McpContent> { McpContent.FromText(meta.ToJsonString()) };
        if (includeImage)
        {
            using var image = AgentOps.Render(doc);
            if (image.Width > 1568 || image.Height > 1568)
                output[0] = McpContent.FromText(meta.ToJsonString() + "\nPreview scaled down; coordinates refer to the full-size image.");
            output.Add(McpContent.FromImage(AgentOps.Preview(image), "image/jpeg"));
        }
        return output;
    }

    private static readonly JsonObject AnchorSchema = new()
    {
        ["type"] = "object",
        ["description"] = "Where to place it: {\"text\": \"Save\"} (found by OCR), {\"x\":…, \"y\":…}, or {\"rect\": [x, y, w, h]} in image pixels.",
        ["properties"] = new JsonObject
        {
            ["text"] = new JsonObject { ["type"] = "string" }, ["occurrence"] = new JsonObject { ["type"] = "integer" },
            ["x"] = new JsonObject { ["type"] = "number" }, ["y"] = new JsonObject { ["type"] = "number" },
            ["rect"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "number" } },
        },
    };

    private static JsonObject Prop(string type, string? description = null)
    {
        var o = new JsonObject { ["type"] = type };
        if (description != null) o["description"] = description;
        return o;
    }

    private static JsonObject Schema(JsonObject properties, params string[] required)
    {
        var o = new JsonObject { ["type"] = "object", ["properties"] = properties };
        if (required.Length > 0) o["required"] = new JsonArray(required.Select(r => (JsonNode)r).ToArray());
        return o;
    }

    private static Task<IReadOnlyList<McpContent>> Done(IReadOnlyList<McpContent> c) => Task.FromResult(c);

    public static IReadOnlyList<McpTool> All =>
    [
        new("capture",
            "Take a screenshot. Give `app` (and optionally `title`) to capture that app's front window, `window_id` from list_windows, `rect` in screen pixels, or nothing for the whole main display. Returns the saved PNG path, its size and a preview.",
            Schema(new JsonObject
            {
                ["app"] = Prop("string", "App or process name, e.g. msedge, Notepad or Settings."),
                ["title"] = Prop("string", "Part of the window title (with app)."),
                ["window_id"] = Prop("integer"),
                ["rect"] = new JsonObject { ["type"] = "array", ["items"] = Prop("number"), ["description"] = "[x, y, width, height] in screen pixels." },
                ["display"] = Prop("integer", "Display index for a full-screen capture."),
                ["interactive"] = Prop("boolean", "Let the user select an area or window (needs the RasterNest app)."),
                ["cursor"] = Prop("boolean", "Include the mouse pointer."),
                ["delay"] = Prop("number", "Seconds to wait first."),
                ["output"] = Prop("string", "PNG path. Default: Pictures\\RasterNest\\agent\\<timestamp>.png"),
                ["include_image"] = Prop("boolean", "Return a preview image (default true)."),
            }),
            async args =>
            {
                if (args.Num("delay") is double delay && delay > 0) await Task.Delay(TimeSpan.FromSeconds(delay));
                if (args.Bool("interactive") == true) throw new UsageException("Interactive capture needs the RasterNest app on Windows. Capture an `app` window or a `rect` instead.");
                Captured shot;
                if (args.Int("window_id") is { } id) shot = ScreenCapture.CaptureWindow((uint)id, args.Bool("cursor") == true);
                else
                {
                    var rect = (args["rect"] as JsonArray)?.Select(n => n?.GetValue<double>() ?? 0).ToList();
                    shot = ScreenCapture.Capture(new CaptureSpec
                    {
                        App = S(args, "app"), Title = S(args, "title"), Rect = rect, Display = args.Int("display"), Cursor = args.Bool("cursor"),
                    }, null);
                }
                using var _ = shot.Bitmap;
                var png = shot.Png();
                var path = OutputPath(S(args, "output"), "png");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await File.WriteAllBytesAsync(path, png);
                return Describe(path, new NestDocument(png, shot.Scale, []), args.Bool("include_image") ?? true);
            }),

        new("record",
            "Record the screen to a GIF (and/or MP4) for docs or demos. Target `app` (front window of that app), `window_id`, `rect` (screen pixels) or a whole display. Recording lasts `duration` seconds, or, with `during`, until that command (run with cmd.exe) finishes. Use `during` to drive the demo (e.g. `start https://…` or a script); otherwise the user acts while it records. Returns file paths and a preview frame.",
            Schema(new JsonObject
            {
                ["app"] = Prop("string", "Record this app's front window."),
                ["title"] = Prop("string", "With app: part of the window title."),
                ["window_id"] = Prop("integer"),
                ["rect"] = new JsonObject { ["type"] = "array", ["items"] = Prop("number"), ["description"] = "[x, y, width, height] in screen pixels." },
                ["display"] = Prop("integer"),
                ["duration"] = Prop("number", "Seconds (default 5 when `during` is not given; max 120)."),
                ["during"] = Prop("string", "Command run while recording; recording stops when it exits unless duration is set."),
                ["delay"] = Prop("number", "Seconds to wait before starting."),
                ["format"] = Prop("string", "gif (default), mp4, or both."),
                ["output"] = Prop("string", "Output path (.gif or .mp4). Default: Pictures\\RasterNest\\agent\\<timestamp>."),
                ["gif_width"] = Prop("integer", "GIF width in pixels (default 800; 0 = full size)."),
                ["gif_fps"] = Prop("number", "GIF frame rate (default 12)."),
                ["cursor"] = Prop("boolean", "Show the pointer (default true)."),
                ["include_image"] = Prop("boolean", "Return a preview frame (default true)."),
            }),
            async args =>
            {
                var req = new RecordRequest
                {
                    WindowId = args.Int("window_id") is { } id ? (uint)id : null,
                    Capture = new CaptureSpec
                    {
                        App = S(args, "app"), Title = S(args, "title"), Display = args.Int("display"),
                        Rect = (args["rect"] as JsonArray)?.Select(n => n?.GetValue<double>() ?? 0).ToList(),
                    },
                    During = S(args, "during"),
                    Cursor = args.Bool("cursor") ?? true,
                    GifWidth = args.Int("gif_width") ?? 800,
                    GifFps = args.Num("gif_fps") ?? 12,
                    MaxDuration = 120,
                };
                var duration = Math.Min(120, args.Num("duration") ?? (req.During == null ? 5 : 0));
                req.Duration = duration > 0 ? duration : null;
                var format = (S(args, "format") ?? "gif").ToLowerInvariant();
                var output = S(args, "output") is { } o ? AgentOps.ExpandPath(o) : null;
                var stem = Path.ChangeExtension(output ?? OutputPath(null, "gif"), null);
                switch (output != null ? Path.GetExtension(output).TrimStart('.').ToLowerInvariant() : format)
                {
                    case "mp4" or "mov": req.Mp4 = output ?? stem + ".mp4"; break;
                    case "both": req.Mp4 = stem + ".mp4"; req.Gif = stem + ".gif"; break;
                    default: req.Gif = output ?? stem + ".gif"; break;
                }
                if (format == "both") { req.Mp4 = stem + ".mp4"; req.Gif = stem + ".gif"; }
                if (args.Num("delay") is double delay && delay > 0) await Task.Delay(TimeSpan.FromSeconds(delay));
                var result = await Recording.Record(req, CancellationToken.None, Console.Error.WriteLine);
                var meta = new JsonObject
                {
                    ["seconds"] = Math.Round(result.Seconds, 1), ["width"] = result.Width, ["height"] = result.Height,
                };
                if (result.Gif != null) { meta["gif"] = result.Gif; meta["gif_bytes"] = new FileInfo(result.Gif).Length; }
                if (result.Mp4 != null) meta["mp4"] = result.Mp4;
                var content = new List<McpContent> { McpContent.FromText(meta.ToJsonString()) };
                if ((args.Bool("include_image") ?? true) && await Recording.Preview(result.Mp4, result.Gif) is { } jpeg)
                    content.Add(McpContent.FromImage(jpeg, "image/jpeg"));
                return content;
            }),

        new("ocr",
            "Read the text in an image with positions. Returns lines with boxes {x, y, width, height} in image pixels (origin top-left). Use `find` to get just the box of some text.",
            Schema(new JsonObject
            {
                ["path"] = Prop("string", "PNG/JPEG or .rasternest file."),
                ["find"] = Prop("string", "Only return where this text is."),
                ["words"] = Prop("boolean", "Include per-word boxes (default false)."),
            }, "path"),
            async args =>
            {
                var path = S(args, "path") ?? throw new UsageException("`path` is required.");
                var doc = AgentOps.LoadDocument(AgentOps.ExpandPath(path));
                var result = await TextRecognition.AnalyzeAsync(doc.ImagePng);
                if (S(args, "find") is { } find)
                {
                    var boxes = TextMatcher.Matches(find, result.Lines);
                    return [McpContent.FromText(boxes.Count == 0
                        ? $"\"{find}\" not found. Text present: {JsonSerializer.Serialize(result.Lines.Take(40).Select(l => l.Text))}"
                        : Json(boxes))];
                }
                if (args.Bool("words") != true) result = result with { Lines = result.Lines.Select(l => l with { Words = [] }).ToList() };
                return [McpContent.FromText(Json(result))];
            }),

        new("annotate",
            "Add markup to an image and save it. Each annotation: {\"type\": step|arrow|line|box|ellipse|highlight|text|pixelate|blur|redact|spotlight|magnify|image, …}. " +
            "step: {\"at\": anchor, \"label\"?}. arrow/line: {\"to\": anchor, \"from\"?: anchor, \"label\"?}. box/ellipse/highlight/pixelate/spotlight/magnify: {\"around\": anchor}. " +
            "text: {\"text\": \"…\", \"at\": anchor}. redact: {\"pattern\": email|phone|ipv4|url|card|token} or {\"regex\": \"…\"} or {\"match\": \"literal\"} or {\"around\": anchor}. " +
            "Optional on any: color (name or #RRGGBB), width, size, padding. Anchors: {\"text\": \"Save\"} is best. " +
            "Output .png/.jpg is flattened; .rasternest stays editable in the RasterNest app. Returns the path and a preview.",
            Schema(new JsonObject
            {
                ["input"] = Prop("string", "Image or .rasternest file to annotate."),
                ["annotations"] = new JsonObject
                {
                    ["type"] = "array",
                    ["items"] = Schema(new JsonObject
                    {
                        ["type"] = Prop("string"), ["at"] = AnchorSchema.DeepClone(), ["around"] = AnchorSchema.DeepClone(),
                        ["to"] = AnchorSchema.DeepClone(), ["from"] = AnchorSchema.DeepClone(),
                        ["text"] = Prop("string"), ["label"] = Prop("string"), ["number"] = Prop("integer"),
                        ["pattern"] = Prop("string"), ["regex"] = Prop("string"), ["match"] = Prop("string"),
                        ["color"] = Prop("string"), ["width"] = Prop("number"), ["size"] = Prop("number"),
                        ["padding"] = Prop("number"), ["zoom"] = Prop("number"),
                        ["heads"] = Prop("integer", "Arrows: 2 for heads at both ends."),
                        ["style"] = Prop("string", "pixelate/redact: \"blur\" for a Gaussian blur."),
                        ["file"] = Prop("string", "image: a PNG to place (picture-in-picture); use around (fit) or at (center), zoom to scale."),
                    }, "type"),
                },
                ["frame"] = Prop("string", "none or docs (padding, background, rounded corners, shadow)."),
                ["output"] = Prop("string", "Default: <input>-annotated.png next to the input."),
                ["also_save_editable"] = Prop("boolean", "Also write a .rasternest next to the output (default true)."),
                ["include_image"] = Prop("boolean"),
            }, "input"),
            async args =>
            {
                var input = S(args, "input") ?? throw new UsageException("`input` is required.");
                var inPath = AgentOps.ExpandPath(input);
                var items = (args["annotations"] as JsonArray)?.Deserialize<List<SpecItem>>(RasterNestJson.Options) ?? [];
                var spec = new AnnotationSpec { Frame = S(args, "frame"), Annotations = items };
                var doc = AgentOps.LoadDocument(inPath);
                await AgentOps.Apply(spec, doc, Path.GetDirectoryName(inPath));
                var outPath = S(args, "output") is { } o ? AgentOps.ExpandPath(o)
                    : Path.Combine(Path.GetDirectoryName(inPath)!, Path.GetFileNameWithoutExtension(inPath) + "-annotated.png");
                AgentOps.Write(doc, outPath);
                var output = Describe(outPath, doc, args.Bool("include_image") ?? true);
                if ((args.Bool("also_save_editable") ?? true) && !outPath.EndsWith("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
                {
                    var docPath = Path.ChangeExtension(outPath, NestDocument.FileExtension);
                    AgentOps.Write(doc, docPath);
                    output.Insert(1, McpContent.FromText($"Editable copy: {docPath}"));
                }
                return output;
            }),

        new("export",
            "Flatten .rasternest files to PNG/JPEG, combine several captures into one PDF, or convert an MP4 recording to GIF.",
            Schema(new JsonObject
            {
                ["inputs"] = new JsonObject { ["type"] = "array", ["items"] = Prop("string") },
                ["format"] = Prop("string", "png, jpg, pdf or gif."),
                ["output"] = Prop("string"),
                ["page_size"] = Prop("string", "PDF: fit, letter or a4."),
                ["captions"] = Prop("boolean", "PDF: file name under each image."),
            }, "inputs"),
            args =>
            {
                var inputs = (args["inputs"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().ToList() ?? [];
                if (inputs.Count == 0) throw new UsageException("`inputs` is required.");
                var path = Program.PerformExport(new Program.ExportRequest(inputs, S(args, "format"), S(args, "output"),
                                                                           S(args, "page_size") ?? "fit", args.Bool("captions") == true))
                           ?? throw new UsageException("Export needs an output file.");
                return Done([McpContent.FromText(path)]);
            }),

        new("combine",
            "Combine several images or .rasternest files into one image: side by side (before/after), stacked, or a grid. Returns the path and a preview.",
            Schema(new JsonObject
            {
                ["inputs"] = new JsonObject { ["type"] = "array", ["items"] = Prop("string"), ["description"] = "Files in order (at least two)." },
                ["layout"] = Prop("string", "horizontal (default), vertical or grid."),
                ["gap"] = Prop("number", "Space between images in points (default 24)."),
                ["padding"] = Prop("number", "Space around the outside in points (default 0)."),
                ["columns"] = Prop("integer", "Grid columns."),
                ["match_sizes"] = Prop("boolean", "Match heights/widths (default true)."),
                ["background"] = Prop("string", "white (default), none, a color name or #RRGGBB."),
                ["numbers"] = Prop("boolean", "Step number badge on each image (good for install/setup sequences)."),
                ["output"] = Prop("string", ".png, .jpg or .rasternest. Default: Pictures\\RasterNest\\agent\\<timestamp>.png"),
            }, "inputs"),
            args =>
            {
                var inputs = (args["inputs"] as JsonArray)?.Select(n => n?.GetValue<string>()).OfType<string>().Select(AgentOps.ExpandPath).ToList() ?? [];
                if (inputs.Count < 2) throw new UsageException("`inputs` needs at least two files.");
                var path = AgentOps.Combine(inputs, S(args, "layout") ?? "horizontal", args.Num("gap") ?? 24, args.Num("padding") ?? 0,
                                            args.Int("columns"), args.Bool("match_sizes") ?? true, S(args, "background") ?? "white",
                                            args.Bool("numbers") == true, OutputPath(S(args, "output"), "png"));
                return Done(Describe(path, AgentOps.LoadDocument(path), true));
            }),

        new("run_guide",
            "Build or rebuild a step-by-step guide from a guide JSON file: captures each step, applies its annotations, and writes images, Markdown and an optional PDF. Format: {\"title\", \"output\"?, \"frame\"?, \"markdown\"?, \"pdf\"?, \"steps\": [{\"name\", \"caption\", \"before\"? (cmd.exe command), \"wait\"? (s), \"capture\": {\"app\"|\"window\"|\"rect\"|\"fullscreen\"|\"file\"}, \"annotations\": [...]}]}.",
            Schema(new JsonObject
            {
                ["path"] = Prop("string"),
                ["steps"] = new JsonObject { ["type"] = "array", ["items"] = Prop("string"), ["description"] = "Only rebuild these steps (names or numbers)." },
            }, "path"),
            async args =>
            {
                var path = S(args, "path") ?? throw new UsageException("`path` is required.");
                var only = (args["steps"] as JsonArray)?.Select(n => n?.ToString()).OfType<string>().ToHashSet() ?? [];
                var report = await AgentOps.RunGuide(AgentOps.ExpandPath(path), only, Console.Error.WriteLine);
                var lines = report.Images.ToList();
                if (report.Markdown != null) lines.Add($"Markdown: {report.Markdown}");
                if (report.Pdf != null) lines.Add($"PDF: {report.Pdf}");
                return [McpContent.FromText(string.Join("\n", lines))];
            }),

        new("list_windows",
            "On-screen windows with id, app, title and frame (screen pixels).",
            Schema(new JsonObject { ["app"] = Prop("string", "Only this app.") }),
            args =>
            {
                var list = ScreenCapture.Windows();
                if (S(args, "app") is { } app)
                    list = list.Where(w => w.Owner.Contains(app, StringComparison.OrdinalIgnoreCase) || w.Process.Contains(app, StringComparison.OrdinalIgnoreCase)).ToList();
                return Done([McpContent.FromText(Json(list))]);
            }),

        new("list_displays",
            "Displays with index, size, position and scale.",
            Schema(new JsonObject()),
            _ => Done([McpContent.FromText(Json(ScreenCapture.Displays()))])),

        new("open_in_editor",
            "Open an image or .rasternest file in the RasterNest editor so the user can adjust it.",
            Schema(new JsonObject { ["path"] = Prop("string") }, "path"),
            args =>
            {
                var path = S(args, "path") ?? throw new UsageException("`path` is required.");
                AgentOps.OpenInEditor(AgentOps.ExpandPath(path));
                return Done([McpContent.FromText($"Opened {path} in RasterNest.")]);
            }),
    ];
}
