using System.Diagnostics;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;
using SkiaSharp;

namespace RasterNest.Cli;

/// <summary>A mistake in how a command was called; printed without a stack trace.</summary>
public sealed class UsageException(string message) : Exception(message);

/// <summary>The building blocks behind annotate, export, combine, guide and the MCP server.</summary>
public static class AgentOps
{
    public static string ExpandPath(string path)
    {
        if (path.StartsWith('~')) path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..];
        return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));
    }

    public static string Resolve(string path, string? baseDir)
    {
        if (path.StartsWith('~')) return ExpandPath(path);
        return Path.IsPathRooted(path) ? Path.GetFullPath(path) : Path.GetFullPath(path, baseDir ?? Environment.CurrentDirectory);
    }

    // MARK: images

    /// <summary>PNG bytes for any input image (converts JPEG, BMP, GIF, WebP…).</summary>
    public static byte[] PngData(byte[] data, string name)
    {
        if (PngInfo.Read(data) != null) return data;
        var decoded = ImageCodec.Decode(data) ?? throw new UsageException($"Could not read {name} as an image.");
        using var bitmap = decoded.Bitmap;
        return ImageCodec.EncodePng(bitmap, decoded.Scale);
    }

    /// <summary>An editable document for an image or a .rasternest file.</summary>
    public static NestDocument LoadDocument(string path)
    {
        if (!File.Exists(path)) throw new UsageException($"{path} doesn't exist.");
        var data = File.ReadAllBytes(path);
        if (Path.GetExtension(path).Equals("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
            return NestDocument.Decoded(data);
        var png = PngData(data, Path.GetFileName(path));
        return new NestDocument(png, PngInfo.Read(png)?.Scale ?? 1, []);
    }

    public static SizeD PixelSize(NestDocument doc) =>
        PngInfo.Read(doc.ImagePng) is { } info ? new SizeD(info.Width, info.Height) : throw new UsageException("The document's image isn't a PNG.");

    /// <summary>Adds the spec's markup (and frame) to doc. OCR runs only when the spec refers to text.</summary>
    public static async Task Apply(AnnotationSpec spec, NestDocument doc, string? baseDir = null, OcrResult? cached = null)
    {
        IReadOnlyList<TextLine> lines = [];
        if (spec.NeedsOcr) lines = cached?.Lines ?? (await TextRecognition.AnalyzeAsync(doc.ImagePng)).Lines;
        var size = PixelSize(doc);
        var added = spec.Resolve(size, doc.PixelScale, lines, Annotation.NextStepNumber(doc.Annotations), baseDir);
        // Keep labels inside the image now that the real text size is known.
        foreach (var a in added.Where(a => a.Kind == AnnotationKind.Text))
        {
            TextMetrics.Layout(a);
            var r = a.Rect;
            var dx = Math.Min(0, size.Width - r.MaxX) + Math.Max(0, -r.MinX);
            var dy = Math.Min(0, size.Height - r.MaxY) + Math.Max(0, -r.MinY);
            a.Translate(dx, dy);
        }
        doc.Annotations.AddRange(added);
        if (spec.Effects(doc.PixelScale) is { } effects) doc.Effects = effects;
    }

    /// <summary>Writes doc as .rasternest, or flattened as PNG/JPEG, based on the extension.</summary>
    public static void Write(NestDocument doc, string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (ext == NestDocument.FileExtension) { doc.Save(path); return; }
        var format = ExportFormats.FromExtension(ext.Length == 0 ? "png" : ext)
            ?? throw new UsageException($"Unsupported output type `.{ext}`. Use .png, .jpg or .rasternest.");
        using var image = Render(doc);
        File.WriteAllBytes(path, ImageCodec.Encode(image, format, doc.PixelScale));
    }

    public static SKImage Render(NestDocument doc)
    {
        var decoded = ImageCodec.Decode(doc.ImagePng) ?? throw new UsageException("The document's picture is damaged.");
        using var bitmap = decoded.Bitmap;
        return new AnnotationRenderer(doc.PixelScale).Flatten(bitmap, doc.Annotations, doc.Effects);
    }

    /// <summary>A document with its annotations and frame burned in, or a plain image as-is.</summary>
    public static (SKImage Image, double Scale) Flattened(string path)
    {
        if (Path.GetExtension(path).Equals("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
        {
            var doc = NestDocument.Load(path);
            return (Render(doc), doc.PixelScale);
        }
        if (!File.Exists(path)) throw new UsageException($"{path} doesn't exist.");
        var decoded = ImageCodec.Load(path) ?? throw new UsageException($"Could not read {path}.");
        using var bitmap = decoded.Bitmap;
        return (SKImage.FromBitmap(bitmap), decoded.Scale);
    }

    /// <summary>A small JPEG of an image for an AI model to look at (long side ≤ maxSide).</summary>
    public static byte[] Preview(SKImage image, int maxSide = 1568)
    {
        var longest = Math.Max(image.Width, image.Height);
        var factor = Math.Min(1, (double)maxSide / longest);
        int w = Math.Max(1, (int)(image.Width * factor)), h = Math.Max(1, (int)(image.Height * factor));
        using var surface = SKSurface.Create(new SKImageInfo(w, h, SKColorType.Rgba8888, SKAlphaType.Opaque));
        surface.Canvas.Clear(SKColors.White);
        surface.Canvas.DrawImage(image, new SKRect(0, 0, w, h), new SKSamplingOptions(SKCubicResampler.Mitchell));
        using var small = surface.Snapshot();
        return ImageCodec.Encode(small, ExportFormat.Jpg, 1, 80);
    }

    // MARK: combine

    public static string Combine(IReadOnlyList<string> inputs, string arrangement, double gap, double padding, int? columns,
                                 bool matchSizes, string background, bool numbered, string output)
    {
        if (!Enum.TryParse<CombineArrangement>(arrangement, ignoreCase: true, out var arr))
            throw new UsageException("Layout must be horizontal, vertical or grid.");
        var images = inputs.Select(Flattened).ToList();
        try
        {
            var scale = images.Max(i => i.Scale);
            var layout = new CombineLayout { Arrangement = arr, Gap = gap * scale, Padding = padding * scale, Columns = columns, MatchSizes = matchSizes };
            Rgba? bg = background.ToLowerInvariant() is "none" or "transparent" or "clear" ? null : AnnotationSpec.ParseColor(background);
            var dir = Path.GetDirectoryName(output);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            if (Path.GetExtension(output).Equals("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
            {
                // Editable: each picture is its own layer in the document.
                var r = ImageCombiner.Layered(images, layout, bg, numbered) ?? throw new UsageException("Combining failed.");
                using var canvas = r.Canvas;
                ImageCodec.MakeDocument(canvas, r.Scale, r.Layers).Save(output);
            }
            else
            {
                var r = ImageCombiner.Combine(images, layout, bg, numbered) ?? throw new UsageException("Combining failed.");
                using var image = r.Image;
                var ext = Path.GetExtension(output).TrimStart('.');
                var fmt = ExportFormats.FromExtension(ext.Length == 0 ? "png" : ext) ?? ExportFormat.Png;
                File.WriteAllBytes(output, ImageCodec.Encode(image, fmt, r.Scale));
            }
            return output;
        }
        finally { foreach (var (image, _) in images) image.Dispose(); }
    }

    // MARK: shell

    /// <summary>Runs a guide step's before command with cmd.exe (so `start ms-settings:` and app names work).</summary>
    public static void RunShell(string command, string workingDirectory)
    {
        var psi = new ProcessStartInfo("cmd.exe", ["/d", "/s", "/c", command])
        {
            WorkingDirectory = workingDirectory, UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true,
        };
        using var p = Process.Start(psi) ?? throw new UsageException($"Couldn't run `{command}`.");
        // Keep stdout clean for MCP and scripts.
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Console.Error.WriteLine(e.Data); };
        p.BeginOutputReadLine();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new UsageException($"`{command}` exited with status {p.ExitCode}.");
    }

    // MARK: guides

    public sealed class GuideReport
    {
        public List<string> Images { get; } = [];
        public List<string> Documents { get; } = [];
        public string? Markdown { get; set; }
        public string? Pdf { get; set; }
    }

    /// <summary>Captures, annotates and writes every step of a guide (or just the steps in only).</summary>
    public static async Task<GuideReport> RunGuide(string guidePath, IReadOnlySet<string> only, Action<string> log)
    {
        var guide = Guide.Decoded(File.ReadAllText(guidePath));
        var baseDir = Path.GetDirectoryName(Path.GetFullPath(guidePath))!;
        var stemName = Path.GetFileNameWithoutExtension(guidePath);
        var outDir = Resolve(guide.Output ?? $"{stemName}-images", baseDir);
        Directory.CreateDirectory(outDir);

        var report = new GuideReport();
        for (var i = 0; i < guide.Steps.Count; i++)
        {
            var step = guide.Steps[i];
            var stem = guide.Stem(i);
            var imagePath = Path.Combine(outDir, stem + ".png");
            var docPath = Path.Combine(outDir, stem + "." + NestDocument.FileExtension);
            if (only.Count > 0 && !only.Contains(step.Name ?? "") && !only.Contains((i + 1).ToString()))
            {
                report.Images.Add(imagePath);
                continue;
            }
            log($"[{i + 1}/{guide.Steps.Count}] {step.Caption ?? stem}");
            if (step.Before is { } before) RunShell(before, baseDir);
            if (step.Wait is > 0) await Task.Delay(TimeSpan.FromSeconds(step.Wait.Value));
            var shot = ScreenCapture.Capture(step.Capture, baseDir);
            NestDocument doc;
            using (shot.Bitmap) doc = new NestDocument(shot.Png(), shot.Scale, []);
            var spec = new AnnotationSpec { Frame = step.Frame ?? guide.Frame, Annotations = step.Annotations ?? [] };
            try { await Apply(spec, doc, baseDir); }
            catch (Exception e) { throw new UsageException($"Step {i + 1} ({stem}): {e.Message}"); }
            Write(doc, docPath);
            Write(doc, imagePath);
            report.Images.Add(imagePath);
            report.Documents.Add(docPath);
        }

        if (guide.Markdown != "")
        {
            var mdPath = Resolve(guide.Markdown ?? $"{stemName}.md", baseDir);
            var mdDir = Path.GetDirectoryName(mdPath)!;
            var md = guide.ToMarkdown(report.Images.Select(p => Path.GetRelativePath(mdDir, p).Replace('\\', '/')).ToList());
            Directory.CreateDirectory(mdDir);
            File.WriteAllText(mdPath, md);
            report.Markdown = mdPath;
        }

        if (guide.Pdf is { Length: > 0 } pdf)
        {
            var pdfPath = Resolve(pdf, baseDir);
            var pages = new List<PdfComposer.Page>();
            for (var i = 0; i < report.Images.Count; i++)
            {
                if (ImageCodec.Load(report.Images[i]) is not { } loaded) continue;
                using var bitmap = loaded.Bitmap;
                pages.Add(new PdfComposer.Page(SKImage.FromBitmap(bitmap), loaded.Scale, guide.Steps[i].Caption));
            }
            PdfComposer.Write(pages, pdfPath, PdfComposer.PageSize.Fit, title: guide.Title);
            foreach (var p in pages) p.Image.Dispose();
            report.Pdf = pdfPath;
        }
        return report;
    }

    /// <summary>Opens a file in the RasterNest app (registered for .rasternest and the rasternest: link).</summary>
    public static void OpenInEditor(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo($"rasternest://open?path={Uri.EscapeDataString(path)}") { UseShellExecute = true });
        }
        catch
        {
            throw new UsageException("Couldn't open the RasterNest app. Install it with `winget install A2M4.RasterNest`, then try again.");
        }
    }
}
