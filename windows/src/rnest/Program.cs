using System.CommandLine;
using System.Text;
using System.Text.Json;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;
using SkiaSharp;

namespace RasterNest.Cli;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        var root = new RootCommand("RasterNest: capture, annotate and share screenshots from the command line.");
        root.Subcommands.Add(CaptureCommand());
        root.Subcommands.Add(RecordCommand());
        root.Subcommands.Add(OcrCommand());
        root.Subcommands.Add(AnnotateCommand());
        root.Subcommands.Add(CombineCommand());
        root.Subcommands.Add(ExportCommand());
        root.Subcommands.Add(GuideCommand());
        root.Subcommands.Add(McpCommand());
        root.Subcommands.Add(EditCommand());
        root.Subcommands.Add(DisplaysCommand());
        root.Subcommands.Add(WindowsCommand());
        root.Subcommands.Add(BackendsCommand());
        return await root.Parse(args).InvokeAsync();
    }

    // MARK: helpers

    private static Func<ParseResult, CancellationToken, Task<int>> Run(Func<ParseResult, CancellationToken, Task> body) => async (r, ct) =>
    {
        try
        {
            await body(r, ct);
            return 0;
        }
        catch (Exception e) when (e is UsageException or CaptureException or SpecException or UnsupportedVersionException
                                       or IOException or UnauthorizedAccessException or JsonException)
        {
            Console.Error.WriteLine($"Error: {e.Message}");
            return 1;
        }
        catch (ExitException e) { return e.Code; }
    };

    private sealed class ExitException(int code) : Exception { public int Code { get; } = code; }

    internal static void PrintJson<T>(T value) => Console.WriteLine(RasterNestJson.Serialize(value, pretty: true));

    private static RectD ParseRect(string s)
    {
        var parts = s.Split(',').Select(p => double.TryParse(p.Trim(), System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : (double?)null).ToArray();
        if (parts.Length != 4 || parts.Any(p => p == null) || parts[2] <= 0 || parts[3] <= 0)
            throw new UsageException("--rect must look like x,y,width,height (e.g. 0,0,800,600).");
        return new RectD(parts[0]!.Value, parts[1]!.Value, parts[2]!.Value, parts[3]!.Value);
    }

    private static Option<bool> Flag(string name, string description, params string[] aliases) => new(name, aliases) { Description = description };
    private static Option<T> Opt<T>(string name, string description, params string[] aliases) => new(name, aliases) { Description = description };

    private static byte[] ReadAllStdin()
    {
        using var stdin = Console.OpenStandardInput();
        using var ms = new MemoryStream();
        stdin.CopyTo(ms);
        return ms.ToArray();
    }

    // MARK: capture

    private static Command CaptureCommand()
    {
        var region = Flag("--region", "Drag out an area to capture (opens the RasterNest app).");
        var window = Flag("--window", "Click a window to capture (opens the RasterNest app).");
        var fullscreen = Flag("--fullscreen", "Capture a whole display.", "-f");
        var display = Opt<int?>("--display", "Display index for --fullscreen (see `rnest displays`).");
        var rect = Opt<string?>("--rect", "Exact area in screen pixels: x,y,width,height (origin top-left of the main display).");
        var windowId = Opt<uint?>("--window-id", "Capture a specific window (see `rnest windows`).");
        var app = Opt<string?>("--app", "Capture the front window of this app (process or app name, e.g. msedge or Notepad).");
        var title = Opt<string?>("--title", "With --app: a window whose title contains this.");
        var output = Opt<string?>("--output", "Output file. Use - for stdout. Default: Pictures\\RasterNest\\<timestamp>.png", "-o");
        var clipboard = Flag("--clipboard", "Copy the result to the clipboard.", "-c");
        var text = Flag("--text", "Recognize text in the capture and print it instead of saving an image.");
        var delay = Opt<double>("--delay", "Seconds to wait before capturing.");
        var edit = Flag("--edit", "Open the capture in the RasterNest editor.", "-e");
        var cursor = Flag("--cursor", "Include the mouse pointer.");
        var backend = Opt<string?>("--backend", "Capture backend (Windows has one: gdi).");
        var quiet = Flag("--quiet", "Only print errors.", "-q");

        var cmd = new Command("capture", "Take a screenshot of a display, an area or a window.")
        {
            region, window, fullscreen, display, rect, windowId, app, title, output, clipboard, text, delay, edit, cursor, backend, quiet,
        };
        cmd.SetAction(Run(async (r, ct) =>
        {
            var modes = new[] { r.GetValue(region), r.GetValue(window), r.GetValue(fullscreen), r.GetValue(rect) != null,
                                r.GetValue(windowId) != null, r.GetValue(app) != null }.Count(b => b);
            if (modes > 1) throw new UsageException("Choose only one of --region, --window, --fullscreen, --rect, --window-id, --app.");
            if (r.GetValue(display) != null && !r.GetValue(fullscreen)) throw new UsageException("--display requires --fullscreen.");
            if (r.GetValue(backend) is { } b && !b.Equals("gdi", StringComparison.OrdinalIgnoreCase))
                throw new UsageException("Only the `gdi` backend exists on Windows.");
            var d = r.GetValue(delay);
            if (d < 0) throw new UsageException("--delay must be zero or more.");
            var q = r.GetValue(quiet);
            if (r.GetValue(region) || r.GetValue(window))
                throw new UsageException("Interactive capture needs the RasterNest app (press Print Screen once it's installed). Use --fullscreen, --rect, --app or --window-id here.");
            if (d > 0)
            {
                if (!q) Console.Error.WriteLine($"Capturing in {d}s…");
                await Task.Delay(TimeSpan.FromSeconds(d), ct);
            }
            var withCursor = r.GetValue(cursor);
            Captured shot;
            if (r.GetValue(rect) is { } rs) shot = ScreenCapture.CaptureRect(ParseRect(rs), withCursor);
            else if (r.GetValue(windowId) is { } id) shot = ScreenCapture.CaptureWindow(id, withCursor);
            else if (r.GetValue(app) is { } a) shot = ScreenCapture.CaptureWindow(ScreenCapture.FindWindow(a, r.GetValue(title), null).Id, withCursor);
            else shot = ScreenCapture.CaptureDisplay(r.GetValue(display), withCursor);
            using var _ = shot.Bitmap;
            var png = shot.Png();

            if (r.GetValue(text))
            {
                var recognized = await TextRecognition.RecognizeAsync(png);
                Console.WriteLine(recognized);
                if (r.GetValue(clipboard)) RasterNest.Windows.Clipboard.CopyText(recognized);
                return;
            }
            if (r.GetValue(clipboard)) RasterNest.Windows.Clipboard.CopyPng(png);
            var o = r.GetValue(output);
            if (o == "-")
            {
                using var stdout = Console.OpenStandardOutput();
                stdout.Write(png);
                return;
            }
            // With only --clipboard there's nothing to save unless asked.
            if (o == null && r.GetValue(clipboard) && !r.GetValue(edit))
            {
                if (!q) Console.Error.WriteLine("Copied to clipboard.");
                return;
            }
            var path = o != null ? AgentOps.ExpandPath(o) : Path.Combine(CaptureNaming.DefaultCaptureFolder(), CaptureNaming.TimestampedName() + ".png");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await File.WriteAllBytesAsync(path, png, ct);
            if (!q) Console.WriteLine(path);
            if (r.GetValue(edit)) AgentOps.OpenInEditor(path);
        }));
        return cmd;
    }

    private static Command RecordCommand()
    {
        var cmd = new Command("record", "Record the screen, a window or an area to MP4 and/or GIF.");
        // Accept everything so scripts written for the Mac get a clear message rather than a parse error.
        cmd.TreatUnmatchedTokensAsErrors = false;
        cmd.SetAction(Run((r, ct) => throw new UsageException("Screen recording isn't in the Windows version yet; it's coming in the next release.")));
        return cmd;
    }

    // MARK: ocr

    private static Command OcrCommand()
    {
        var image = new Argument<string>("image") { Description = "Image file, or - to read from stdin." };
        var clipboard = Flag("--clipboard", "Also copy the text to the clipboard.", "-c");
        var json = Flag("--json", "Print lines and words with their positions (image pixels, origin top-left) as JSON.");
        var find = Opt<string?>("--find", "Print only the box of this text as JSON (best match first; see --all).");
        var all = Flag("--all", "With --find, print every match instead of the best one.");
        var cmd = new Command("ocr", "Print the text found in an image (Windows OCR).") { image, clipboard, json, find, all };
        cmd.SetAction(Run(async (r, ct) =>
        {
            var input = r.GetValue(image)!;
            var data = input == "-" ? ReadAllStdin() : await File.ReadAllBytesAsync(AgentOps.ExpandPath(input), ct);
            if (input != "-" && input.EndsWith("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
                data = NestDocument.Decoded(data).ImagePng;
            var result = await TextRecognition.AnalyzeAsync(AgentOps.PngData(data, input));
            if (r.GetValue(find) is { } f)
            {
                var boxes = TextMatcher.Matches(f, result.Lines);
                if (boxes.Count == 0)
                {
                    Console.Error.WriteLine($"\"{f}\" not found.");
                    throw new ExitException(1);
                }
                if (r.GetValue(all)) PrintJson(boxes); else PrintJson(boxes[0]);
                return;
            }
            if (r.GetValue(json)) { PrintJson(result); return; }
            Console.WriteLine(result.Text);
            if (r.GetValue(clipboard)) RasterNest.Windows.Clipboard.CopyText(result.Text);
        }));
        return cmd;
    }

    // MARK: annotate

    private static Command AnnotateCommand()
    {
        var input = new Argument<string>("input") { Description = "Image or .rasternest document to annotate." };
        var spec = Opt<string?>("--spec", "Annotation spec JSON file, or - for stdin.");
        var step = Opt<string[]>("--step", "Numbered step next to this text. Repeat for more steps.");
        var box = Opt<string[]>("--box", "Rectangle around this text.");
        var arrow = Opt<string[]>("--arrow", "Arrow pointing at this text.");
        var highlight = Opt<string[]>("--highlight", "Highlight this text.");
        var redact = Opt<string[]>("--redact", "Pixelate matches: email, phone, ipv4, url, card, token, or any literal text.");
        var blur = Flag("--blur", "Blur redactions instead of pixelating them.");
        var frame = Opt<string?>("--frame", "Frame: none or docs.");
        var color = Opt<string?>("--color", "Default color (name or #RRGGBB).");
        var output = Opt<string?>("--output", "Output: .png, .jpg or .rasternest. Default: <input>-annotated.png next to the input.", "-o");
        var edit = Flag("--edit", "Open the result in the RasterNest editor.", "-e");
        var cmd = new Command("annotate", """
            Add markup to an image from a spec or flags, placing it by the text on screen.
            Examples:
              rnest annotate shot.png --step Save --step Allow --redact email
              rnest annotate shot.png --box "Advanced" --arrow "Apply" --frame docs -o step3.png
              rnest annotate shot.png --spec markup.json -o shot.rasternest
            Types: step, arrow, line, box, ellipse, highlight, text, pixelate, blur, redact, spotlight, magnify, image.
            """) { input, spec, step, box, arrow, highlight, redact, blur, frame, color, output, edit };
        foreach (var o in new[] { step, box, arrow, highlight, redact }) o.AllowMultipleArgumentsPerToken = false;
        cmd.SetAction(Run(async (r, ct) =>
        {
            var inPath = AgentOps.ExpandPath(r.GetValue(input)!);
            var items = new List<SpecItem>();
            string? specFrame = null, specColor = null;
            if (r.GetValue(spec) is { } s)
            {
                var json = s == "-" ? Encoding.UTF8.GetString(ReadAllStdin()) : await File.ReadAllTextAsync(AgentOps.ExpandPath(s), ct);
                AnnotationSpec parsed;
                try { parsed = RasterNestJson.Deserialize<AnnotationSpec>(json); }
                catch (JsonException e) { throw new UsageException($"Couldn't read the spec: {e.Message}"); }
                items.AddRange(parsed.Annotations);
                specFrame = parsed.Frame;
                specColor = parsed.Color;
            }
            var styleBlur = r.GetValue(blur) ? "blur" : null;
            items.AddRange((r.GetValue(step) ?? []).Select(t => new SpecItem { Type = "step", At = new SpecAnchor { Text = t } }));
            items.AddRange((r.GetValue(box) ?? []).Select(t => new SpecItem { Type = "box", Around = new SpecAnchor { Text = t } }));
            items.AddRange((r.GetValue(arrow) ?? []).Select(t => new SpecItem { Type = "arrow", To = new SpecAnchor { Text = t } }));
            items.AddRange((r.GetValue(highlight) ?? []).Select(t => new SpecItem { Type = "highlight", Around = new SpecAnchor { Text = t } }));
            items.AddRange((r.GetValue(redact) ?? []).Select(t => RedactionPattern.Named(t) != null
                ? new SpecItem { Type = "redact", Pattern = t, Style = styleBlur }
                : new SpecItem { Type = "redact", Match = t, Style = styleBlur }));
            var annotationSpec = new AnnotationSpec { Frame = r.GetValue(frame) ?? specFrame, Color = r.GetValue(color) ?? specColor, Annotations = items };
            if (items.Count == 0 && annotationSpec.Frame == null)
                throw new UsageException("Nothing to add. Give --spec, or flags like --step, --box, --arrow, --redact or --frame.");
            var doc = AgentOps.LoadDocument(inPath);
            await AgentOps.Apply(annotationSpec, doc, Environment.CurrentDirectory);
            var outPath = r.GetValue(output) is { } o ? AgentOps.ExpandPath(o)
                : Path.Combine(Path.GetDirectoryName(inPath)!, Path.GetFileNameWithoutExtension(inPath) + "-annotated.png");
            AgentOps.Write(doc, outPath);
            Console.WriteLine(outPath);
            if (r.GetValue(edit)) AgentOps.OpenInEditor(outPath);
        }));
        return cmd;
    }

    // MARK: combine

    private static Command CombineCommand()
    {
        var inputs = new Argument<string[]>("inputs") { Description = "Images or .rasternest files, in order.", Arity = ArgumentArity.OneOrMore };
        var layout = Opt<string>("--layout", "horizontal (side by side), vertical (stacked) or grid.");
        layout.DefaultValueFactory = _ => "horizontal";
        var gap = Opt<double>("--gap", "Space between images, in points.");
        gap.DefaultValueFactory = _ => 24;
        var padding = Opt<double>("--padding", "Space around the outside, in points.");
        var columns = Opt<int?>("--columns", "Grid columns (default: near-square).");
        var noMatch = Flag("--no-match", "Keep each image's own size instead of matching heights/widths.");
        var background = Opt<string>("--background", "Background: white, none (transparent), a color name or #RRGGBB.");
        background.DefaultValueFactory = _ => "white";
        var numbers = Flag("--numbers", "Put a step number badge on each image (1, 2, 3…).");
        var output = Opt<string?>("--output", "Output .png, .jpg or .rasternest. Default: combined.png next to the first input.", "-o");
        var clipboard = Flag("--clipboard", "Also copy the result to the clipboard.", "-c");
        var cmd = new Command("combine", "Combine several images or captures into one: side by side, stacked, or a grid.")
            { inputs, layout, gap, padding, columns, noMatch, background, numbers, output, clipboard };
        cmd.SetAction(Run((r, ct) =>
        {
            var files = (r.GetValue(inputs) ?? []).Select(AgentOps.ExpandPath).ToList();
            if (files.Count < 2) throw new UsageException("Give at least two images to combine.");
            var outPath = r.GetValue(output) is { } o ? AgentOps.ExpandPath(o) : Path.Combine(Path.GetDirectoryName(files[0])!, "combined.png");
            var path = AgentOps.Combine(files, r.GetValue(layout)!, r.GetValue(gap), r.GetValue(padding), r.GetValue(columns),
                                        !r.GetValue(noMatch), r.GetValue(background)!, r.GetValue(numbers), outPath);
            if (r.GetValue(clipboard))
            {
                var (image, scale) = AgentOps.Flattened(path);
                using (image) RasterNest.Windows.Clipboard.CopyImage(image, scale);
            }
            Console.WriteLine(path);
            return Task.CompletedTask;
        }));
        return cmd;
    }

    // MARK: export

    internal sealed record ExportRequest(IReadOnlyList<string> Inputs, string? Format, string? Output, string PageSize, bool Captions,
                                         int Quality = 90, bool Clipboard = false);

    /// <summary>Does the export and returns the file written (null when writing to stdout).</summary>
    internal static string? PerformExport(ExportRequest req)
    {
        if (req.Inputs.Count == 0) throw new UsageException("Give at least one file to export.");
        var wantsPdf = string.Equals(req.Format, "pdf", StringComparison.OrdinalIgnoreCase)
                       || (req.Output != null && req.Output.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase));
        if (req.Inputs.Count > 1 && !wantsPdf) throw new UsageException("Several files can only be exported together as --format pdf.");
        var input = AgentOps.ExpandPath(req.Inputs[0]);
        if (wantsPdf)
        {
            if (!Enum.TryParse<PdfComposer.PageSize>(req.PageSize, true, out var size)) throw new UsageException("--page-size must be fit, letter or a4.");
            if (req.Output == "-") throw new UsageException("PDF export needs an output file, not stdout.");
            var pages = req.Inputs.Select(AgentOps.ExpandPath).Select(p =>
            {
                var (image, scale) = AgentOps.Flattened(p);
                return new PdfComposer.Page(image, scale, req.Captions ? Path.GetFileNameWithoutExtension(p) : null);
            }).ToList();
            var outPdf = req.Output != null ? AgentOps.ExpandPath(req.Output) : Path.ChangeExtension(input, "pdf");
            try { PdfComposer.Write(pages, outPdf, size, title: Path.GetFileNameWithoutExtension(outPdf)); }
            finally { foreach (var p in pages) p.Image.Dispose(); }
            return outPdf;
        }
        if (Path.GetExtension(input).ToLowerInvariant() is ".mp4" or ".mov" or ".m4v")
            throw new UsageException("Turning recordings into GIFs isn't in the Windows version yet; it's coming with screen recording.");
        ExportFormat fmt;
        if (req.Format is { } f) fmt = ExportFormats.FromExtension(f) ?? throw new UsageException($"Unknown format `{f}`. Use png or jpg.");
        else if (req.Output is { } o && o != "-" && ExportFormats.FromExtension(Path.GetExtension(o)) is { } fromExt) fmt = fromExt;
        else fmt = ExportFormat.Png;

        var (flat, s) = AgentOps.Flattened(input);
        using (flat)
        {
            var data = ImageCodec.Encode(flat, fmt, s, req.Quality);
            if (req.Clipboard) RasterNest.Windows.Clipboard.CopyImage(flat, s);
            if (req.Output == "-")
            {
                using var stdout = Console.OpenStandardOutput();
                stdout.Write(data);
                return null;
            }
            var outPath = req.Output != null ? AgentOps.ExpandPath(req.Output) : Path.ChangeExtension(input, fmt == ExportFormat.Png ? "png" : "jpg");
            File.WriteAllBytes(outPath, data);
            return outPath;
        }
    }

    private static Command ExportCommand()
    {
        var inputs = new Argument<string[]>("inputs") { Description = "A .rasternest document or an image. Several files for --format pdf.", Arity = ArgumentArity.OneOrMore };
        var format = Opt<string?>("--format", "Output format: png, jpg or pdf. Default: from --output's extension, else png.");
        var pageSize = Opt<string>("--page-size", "PDF page size: fit (each page matches its image), letter or a4.");
        pageSize.DefaultValueFactory = _ => "fit";
        var captions = Flag("--captions", "PDF: print each file's name under its image.");
        var output = Opt<string?>("--output", "Output file. Use - for stdout. Default: next to the input.", "-o");
        var quality = Opt<int>("--quality", "JPEG quality, 0–100.");
        quality.DefaultValueFactory = _ => 90;
        var clipboard = Flag("--clipboard", "Also copy the exported image to the clipboard.", "-c");
        var cmd = new Command("export", "Flatten captures to PNG/JPEG or combine them into a PDF.")
            { inputs, format, pageSize, captions, output, quality, clipboard };
        cmd.SetAction(Run((r, ct) =>
        {
            var path = PerformExport(new ExportRequest(r.GetValue(inputs) ?? [], r.GetValue(format), r.GetValue(output), r.GetValue(pageSize)!,
                                                       r.GetValue(captions), r.GetValue(quality), r.GetValue(clipboard)));
            if (path != null) Console.WriteLine(path);
            return Task.CompletedTask;
        }));
        return cmd;
    }

    // MARK: guide

    private static Command GuideCommand()
    {
        var file = new Argument<string>("file") { Description = "Guide file (JSON)." };
        var step = Opt<string[]>("--step", "Only rebuild this step (name or number). Repeat for more.");
        var run = new Command("run", "Capture and annotate every step, then write the images, Markdown and (optionally) a PDF.") { file, step };
        run.SetAction(Run(async (r, ct) =>
        {
            var report = await AgentOps.RunGuide(AgentOps.ExpandPath(r.GetValue(file)!), (r.GetValue(step) ?? []).ToHashSet(), Console.Error.WriteLine);
            foreach (var p in report.Images) Console.WriteLine(p);
            if (report.Markdown != null) Console.WriteLine(report.Markdown);
            if (report.Pdf != null) Console.WriteLine(report.Pdf);
        }));

        var initFile = new Argument<string>("file") { Description = "Where to write it.", DefaultValueFactory = _ => "guide.json" };
        var force = Flag("--force", "Overwrite an existing file.");
        var init = new Command("init", "Write a starter guide file.") { initFile, force };
        init.SetAction(Run((r, ct) =>
        {
            var path = AgentOps.ExpandPath(r.GetValue(initFile)!);
            if (File.Exists(path) && !r.GetValue(force)) throw new UsageException($"{path} already exists. Use --force to overwrite it.");
            File.WriteAllText(path, RasterNestJson.Serialize(Guide.Example, pretty: true) + "\n");
            Console.WriteLine(path);
            return Task.CompletedTask;
        }));

        return new Command("guide", "Build step-by-step docs from a guide file, and rebuild every screenshot when the UI changes.") { run, init };
    }

    // MARK: mcp

    private static Command McpCommand()
    {
        var cmd = new Command("mcp", """
            Run a Model Context Protocol server on stdio so AI agents can capture, read and annotate screenshots.
              Claude Code:     claude mcp add rasternest -- rnest mcp
              Claude Desktop:  add to claude_desktop_config.json:
                               { "mcpServers": { "rasternest": { "command": "rnest", "args": ["mcp"] } } }
            Captures are saved in Pictures\RasterNest\agent unless a path is given.
            """);
        cmd.SetAction(Run(async (r, ct) =>
        {
            var server = new McpServer("rasternest", RasterNestInfo.Version, McpTools.All, McpTools.Instructions);
            using var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            using var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            while (await stdin.ReadLineAsync(ct) is { } line)
            {
                if (await server.HandleAsync(line) is { } response) await stdout.WriteLineAsync(response);
            }
        }));
        return cmd;
    }

    // MARK: edit / displays / windows / backends

    private static Command EditCommand()
    {
        var file = new Argument<string>("file") { Description = "File to open." };
        var cmd = new Command("edit", "Open an image or .rasternest document in the RasterNest editor.") { file };
        cmd.SetAction(Run((r, ct) => { AgentOps.OpenInEditor(AgentOps.ExpandPath(r.GetValue(file)!)); return Task.CompletedTask; }));
        return cmd;
    }

    private static Command DisplaysCommand()
    {
        var json = Flag("--json", "Print JSON.");
        var cmd = new Command("displays", "List displays (use the index with --fullscreen --display).") { json };
        cmd.SetAction(Run((r, ct) =>
        {
            var list = ScreenCapture.Displays();
            if (r.GetValue(json)) PrintJson(list);
            else foreach (var d in list)
                Console.WriteLine($"{d.Index}\t{d.Width}×{d.Height} @{d.Scale:0.##}x at {d.X},{d.Y}{(d.IsMain ? "\tmain" : "")}\t{d.Name}");
            return Task.CompletedTask;
        }));
        return cmd;
    }

    private static Command WindowsCommand()
    {
        var json = Flag("--json", "Print JSON.");
        var cmd = new Command("windows", "List on-screen windows (use the id with --window-id).") { json };
        cmd.SetAction(Run((r, ct) =>
        {
            var list = ScreenCapture.Windows();
            if (r.GetValue(json)) PrintJson(list);
            else foreach (var w in list)
                Console.WriteLine($"{w.Id}\t{w.Width}×{w.Height}\t{w.Owner}{(w.Title.Length > 0 ? " — " + w.Title : "")}");
            return Task.CompletedTask;
        }));
        return cmd;
    }

    private static Command BackendsCommand()
    {
        var cmd = new Command("backends", "Show which capture backends are available on this machine.");
        cmd.SetAction(Run((r, ct) => { Console.WriteLine("gdi\t(default)"); return Task.CompletedTask; }));
        return cmd;
    }
}
