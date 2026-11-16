using System.Globalization;
using System.Text.RegularExpressions;
using System.Text.Json.Serialization;

namespace RasterNest.Core;

/// <summary>A spec couldn't be turned into annotations. The message is written for people and AI agents.</summary>
public sealed class SpecException(string message) : Exception(message)
{
    public static SpecException UnknownType(string t) => new(
        $"Unknown annotation type `{t}`. Use step, arrow, line, box, ellipse, highlight, text, pixelate, blur, redact, spotlight, magnify or image.");
    public static SpecException MissingAnchor(string type, string field) => new($"`{type}` needs `{field}`.");
    public static SpecException TextNotFound(string text, IReadOnlyList<string> seen)
    {
        var sample = string.Join(", ", seen.Take(25).Select(s => $"\"{s}\""));
        return new($"Couldn't find the text \"{text}\" in the image." + (seen.Count == 0 ? " No text was recognized." : $" Text found: {sample}"));
    }
    public static SpecException BadPattern(string p) => new(
        $"Unknown redaction pattern `{p}`. Use email, phone, ipv4, url, card or token, or give `regex`.");
    public static SpecException BadColor(string c) => new($"Unknown color `{c}`. Use a name like red or blue, or #RRGGBB.");
    public static SpecException BadFrame(string f) => new($"Unknown frame `{f}`. Use none or docs.");
}

/// <summary>
/// A declarative description of markup: "step 1 on Save, arrow to Allow, redact emails".
/// Positions are anchors (OCR text, a point or a rectangle) in image pixels, origin top-left.
/// Same JSON as the Mac/Linux <c>rnest annotate --spec</c>; see docs/AGENTS.md.
/// </summary>
public sealed record AnnotationSpec
{
    /// <summary>none or docs (padding, gradient background, rounded corners, shadow).</summary>
    public string? Frame { get; init; }
    /// <summary>Default color for annotations that don't set one.</summary>
    public string? Color { get; init; }
    public List<SpecItem> Annotations { get; init; } = [];

    /// <summary>True when any anchor or redaction needs recognized text.</summary>
    [JsonIgnore]
    public bool NeedsOcr => Annotations.Any(i => i.Anchors.Any(a => a.Text != null) || i.Type.Equals("redact", StringComparison.OrdinalIgnoreCase));

    /// <summary>The frame to apply, or null to leave the document's frame as it is.</summary>
    public CanvasEffects? Effects(double scale)
    {
        if (Frame == null) return null;
        return Frame.ToLowerInvariant() switch
        {
            "none" or "" => CanvasEffects.None,
            "docs" or "documentation" => CanvasEffects.Documentation(scale),
            _ => throw SpecException.BadFrame(Frame),
        };
    }

    /// <summary>
    /// Concrete annotations for an image of <paramref name="size"/> pixels at <paramref name="scale"/> pixels per point.
    /// <paramref name="startingStep"/> continues numbering after steps that already exist.
    /// </summary>
    public List<Annotation> Resolve(SizeD size, double scale, IReadOnlyList<TextLine> lines, int startingStep = 1,
                                    string? baseDirectory = null)
    {
        var s = Math.Max(1, scale);
        var bounds = new RectD(0, 0, size.Width, size.Height);
        var output = new List<Annotation>();
        var nextStep = startingStep;
        var defaultColor = Color != null ? ParseColor(Color) : Rgba.Red;

        RectD Box(SpecAnchor a, double pad)
        {
            if (a.Text is { } text)
            {
                var found = TextMatcher.Find(text, lines, a.Occurrence ?? 1)
                    ?? throw SpecException.TextNotFound(text, TextMatcher.ReadingOrder(lines).Select(l => l.Text).ToList());
                return found.Rect.Inset(-pad, -pad).Intersect(bounds);
            }
            if (a.Rect is { } r)
            {
                if (r.Count != 4 || r[2] <= 0 || r[3] <= 0) throw new SpecException("`rect` must be [x, y, width, height].");
                return new RectD(r[0], r[1], r[2], r[3]);
            }
            if (a.X is { } x && a.Y is { } y) return new RectD(x, y, 0, 0).Inset(-pad, -pad);
            throw new SpecException("An anchor needs `text`, `x` and `y`, or `rect`.");
        }

        foreach (var item in Annotations)
        {
            var type = item.Type.ToLowerInvariant();
            var color = item.Color != null ? ParseColor(item.Color) : defaultColor;
            var pad = (item.Padding ?? 6) * s;
            var anchor = item.Around ?? item.At ?? item.To;

            switch (type)
            {
                case "step":
                {
                    var a = item.At ?? item.Around ?? item.To ?? throw SpecException.MissingAnchor(type, "at");
                    var target = Box(a, 0);
                    var style = new AnnotationStyle { Color = color, FontSize = (item.Size ?? 14) * s };
                    var r = Math.Max(style.FontSize * 0.85, 8);
                    var gap = 8 * s;
                    // Left of the target, vertically centered; to the right when there's no room.
                    var center = new PointD(target.MinX - gap - r, target.MidY);
                    if (a.Text == null && a.Rect == null) center = target.Center;
                    else if (center.X - r < 0) center = center with { X = Math.Min(size.Width - r, target.MaxX + gap + r) };
                    var n = item.Number ?? nextStep;
                    nextStep = n + 1;
                    output.Add(new Annotation(AnnotationKind.Step, center, number: n, style: style));
                    if ((item.Label ?? item.Text) is { } label)
                        output.Add(MakeLabel(label, new RectD(center.X - r, center.Y - r, r * 2, r * 2), color, item.Size, s, bounds));
                    break;
                }
                case "arrow" or "line":
                {
                    var toA = item.To ?? item.At ?? item.Around ?? throw SpecException.MissingAnchor(type, "to");
                    var target = Box(toA, 4 * s);
                    var start = item.From is { } fromA ? Box(fromA, 0).Center : ArrowStart(target, bounds, 110 * s);
                    var end = toA.Text != null || toA.Rect != null ? EdgePoint(target, start) : target.Center;
                    var style = new AnnotationStyle { Color = color, LineWidth = (item.Width ?? 4) * s, Heads = item.Heads };
                    output.Add(new Annotation(type == "arrow" ? AnnotationKind.Arrow : AnnotationKind.Line, start, end, style: style));
                    if ((item.Label ?? item.Text) is { } label)
                        output.Add(MakeLabel(label, new RectD(start.X, start.Y, 0, 0), color, item.Size, s, bounds));
                    break;
                }
                case "box" or "rectangle" or "rect" or "ellipse" or "circle" or "highlight" or "pixelate" or "blur" or "spotlight" or "magnify":
                {
                    var a = anchor ?? throw SpecException.MissingAnchor(type, "around");
                    var r = Box(a, pad);
                    AnnotationKind kind;
                    AnnotationStyle style;
                    switch (type)
                    {
                        case "ellipse" or "circle":
                            kind = AnnotationKind.Ellipse;
                            style = new() { Color = color, LineWidth = (item.Width ?? 3) * s, Filled = item.Filled ?? false };
                            break;
                        case "highlight":
                            kind = AnnotationKind.Highlight;
                            if (item.Color == null) color = Rgba.Yellow;
                            style = new() { Color = color, LineWidth = 0, Shadow = false, Opacity = 0.45 };
                            break;
                        case "pixelate" or "blur":
                            kind = AnnotationKind.Pixelate;
                            style = new()
                            {
                                Color = Rgba.Black, LineWidth = (item.Width ?? 10) * s, Shadow = false,
                                Blur = type == "blur" || string.Equals(item.Style, "blur", StringComparison.OrdinalIgnoreCase) ? true : null,
                            };
                            break;
                        case "spotlight":
                            kind = AnnotationKind.Spotlight;
                            style = new() { Color = Rgba.Black, LineWidth = 0, Shadow = false, Opacity = 0.55 };
                            break;
                        case "magnify":
                            kind = AnnotationKind.Magnify;
                            style = new() { Color = item.Color == null ? Rgba.White : color, LineWidth = (item.Width ?? 4) * s, Shadow = true, Zoom = item.Zoom ?? 2 };
                            break;
                        default:
                            kind = AnnotationKind.Rectangle;
                            style = new() { Color = color, LineWidth = (item.Width ?? 3) * s, Filled = item.Filled ?? false };
                            break;
                    }
                    output.Add(new Annotation(kind, r.Origin, new PointD(r.MaxX, r.MaxY), style: style));
                    if (item.Label is { } label && kind is AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Highlight)
                        output.Add(MakeLabel(label, r, color, item.Size, s, bounds));
                    break;
                }
                case "text" or "label" or "callout":
                {
                    var text = item.Text ?? item.Label ?? throw SpecException.MissingAnchor(type, "text");
                    var a = item.At ?? item.Around ?? item.To ?? throw SpecException.MissingAnchor(type, "at");
                    var target = Box(a, 0);
                    var ann = MakeLabel(text, target, color, item.Size, s, bounds);
                    if (a.Text == null && a.Rect == null) { ann.Start = target.Center; ann.End = ann.Start; }
                    ann.Style.Filled = item.Callout ?? true;
                    output.Add(ann);
                    break;
                }
                case "image" or "picture":
                {
                    var path = item.File ?? throw SpecException.MissingAnchor(type, "file");
                    var full = ExpandPath(path, baseDirectory);
                    byte[] data;
                    try { data = File.ReadAllBytes(full); }
                    catch { throw new SpecException($"`image` needs a PNG file; couldn't read {path}."); }
                    var info = PngInfo.Read(data) ?? throw new SpecException($"`image` needs a PNG file; couldn't read {path}.");
                    // Native size at this image's density, optionally scaled by zoom; or fit to an `around` rect.
                    var k = (item.Zoom ?? 1) * s / Math.Max(info.Scale, 1);
                    var frame = new RectD(0, 0, info.Width * k, info.Height * k);
                    if (item.Around is { } around && (around.Rect != null || around.Text != null))
                    {
                        var target = Box(around, 0);
                        var f = Math.Min(target.Width / frame.Width, target.Height / frame.Height);
                        var w = frame.Width * f; var h = frame.Height * f;
                        frame = new RectD(target.MidX - w / 2, target.MidY - h / 2, w, h);
                    }
                    else if ((item.At ?? item.Around) is { } at)
                    {
                        var c = Box(at, 0).Center;
                        frame = frame with { X = c.X - frame.Width / 2, Y = c.Y - frame.Height / 2 };
                    }
                    else
                    {
                        frame = frame with { X = (size.Width - frame.Width) / 2, Y = (size.Height - frame.Height) / 2 };
                    }
                    var style = new AnnotationStyle { Color = color, LineWidth = (item.Width ?? 0) * s, Shadow = item.Filled ?? true, Opacity = 1 };
                    output.Add(new Annotation(AnnotationKind.Image, frame.Origin, new PointD(frame.MaxX, frame.MaxY), style: style, imagePng: data));
                    break;
                }
                case "redact":
                {
                    var boxes = new List<PixelBox>();
                    if (item.Pattern is { } p)
                        boxes.AddRange(TextMatcher.Boxes(RedactionPattern.Named(p) ?? throw SpecException.BadPattern(p), lines));
                    if (item.Regex is { } rx)
                    {
                        Regex regex;
                        try { regex = new Regex(rx); } catch (ArgumentException) { throw SpecException.BadPattern(rx); }
                        boxes.AddRange(TextMatcher.Boxes(regex, lines));
                    }
                    if (item.Match is { } m) boxes.AddRange(TextMatcher.Matches(m, lines));
                    if ((item.Around ?? item.At) is { } a) boxes.Add(new PixelBox(Box(a, 0)));
                    if (item.Pattern == null && item.Regex == null && item.Match == null && item.Around == null && item.At == null)
                        throw SpecException.MissingAnchor(type, "pattern, regex, match or around");
                    var style = new AnnotationStyle
                    {
                        Color = Rgba.Black, LineWidth = (item.Width ?? 10) * s, Shadow = false,
                        Blur = string.Equals(item.Style, "blur", StringComparison.OrdinalIgnoreCase) ? true : null,
                    };
                    foreach (var b in boxes)
                    {
                        var r = b.Rect.Inset(-3 * s, -3 * s).Intersect(bounds);
                        if (r.IsNull || r.Width <= 0) continue;
                        output.Add(new Annotation(AnnotationKind.Pixelate, r.Origin, new PointD(r.MaxX, r.MaxY), style: style with { }));
                    }
                    break;
                }
                default:
                    throw SpecException.UnknownType(item.Type);
            }
        }
        return output;
    }

    private static string ExpandPath(string path, string? baseDirectory)
    {
        if (path.StartsWith('~'))
            path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..];
        return Path.IsPathRooted(path) ? path : Path.GetFullPath(path, baseDirectory ?? Environment.CurrentDirectory);
    }

    /// <summary>A text callout beside the target: below it when there's room, otherwise above.</summary>
    private static Annotation MakeLabel(string text, RectD target, Rgba color, double? size, double s, RectD bounds)
    {
        var fontSize = (size ?? 16) * s;
        var estWidth = Math.Min(bounds.Width, new StringInfo(text).LengthInTextElements * fontSize * 0.58 + fontSize);
        var lineH = fontSize * 1.6;
        var origin = new PointD(target.MinX, target.MaxY + 8 * s);
        if (origin.Y + lineH > bounds.MaxY) origin = origin with { Y = Math.Max(0, target.MinY - 8 * s - lineH) };
        origin = origin with { X = Math.Max(0, Math.Min(origin.X, bounds.MaxX - estWidth)) };
        var style = new AnnotationStyle { Color = color, FontSize = fontSize, Filled = true, Shadow = false, LineWidth = 0 };
        return new Annotation(AnnotationKind.Text, origin, new PointD(origin.X + estWidth, origin.Y + lineH), text: text, style: style);
    }

    /// <summary>A start point <paramref name="length"/> away from the target, heading toward the middle of the image.</summary>
    internal static PointD ArrowStart(RectD target, RectD bounds, double length)
    {
        var c = target.Center;
        double dx = bounds.MidX - c.X, dy = bounds.MidY - c.Y;
        if (Math.Abs(dx) < 1 && Math.Abs(dy) < 1) { dx = 1; dy = 1; }
        // Prefer a diagonal approach; it reads as "pointing at" better than a flat one.
        double sx = dx >= 0 ? 1 : -1, sy = dy >= 0 ? 1 : -1;
        var d = length / Math.Sqrt(2);
        var edge = EdgePoint(target, new PointD(c.X + sx * 1000, c.Y + sy * 1000));
        var p = new PointD(edge.X + sx * d, edge.Y + sy * d);
        return new PointD(Math.Max(bounds.MinX + 4, Math.Min(p.X, bounds.MaxX - 4)),
                          Math.Max(bounds.MinY + 4, Math.Min(p.Y, bounds.MaxY - 4)));
    }

    /// <summary>Where the line from p to the rectangle's center crosses its edge.</summary>
    internal static PointD EdgePoint(RectD r, PointD p)
    {
        var c = r.Center;
        double dx = p.X - c.X, dy = p.Y - c.Y;
        if (!(r.Width > 0 || r.Height > 0) || (dx == 0 && dy == 0)) return c;
        var tx = dx == 0 ? double.PositiveInfinity : r.Width / 2 / Math.Abs(dx);
        var ty = dy == 0 ? double.PositiveInfinity : r.Height / 2 / Math.Abs(dy);
        var t = Math.Min(Math.Min(tx, ty), 1);
        return new PointD(c.X + dx * t, c.Y + dy * t);
    }

    public static Rgba ParseColor(string s)
    {
        var key = s.Trim().ToLowerInvariant();
        switch (key)
        {
            case "red": return Rgba.Red;
            case "orange": return Rgba.Orange;
            case "yellow": return Rgba.Yellow;
            case "green": return Rgba.Green;
            case "blue": return Rgba.Blue;
            case "purple" or "violet": return Rgba.Purple;
            case "black": return Rgba.Black;
            case "white": return Rgba.White;
        }
        var hex = key.StartsWith('#') ? key[1..] : key;
        if (hex.Length == 3) hex = string.Concat(hex.Select(c => $"{c}{c}"));
        if (hex.Length != 6 || !uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v))
            throw SpecException.BadColor(s);
        return new Rgba(((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0);
    }
}

/// <summary>Where an annotation goes. Exactly one of text, point (x and y) or rect is used.</summary>
public sealed record SpecAnchor
{
    public string? Text { get; init; }
    /// <summary>Which match of text to use, 1-based, best matches first.</summary>
    public int? Occurrence { get; init; }
    public double? X { get; init; }
    public double? Y { get; init; }
    /// <summary>[x, y, width, height]</summary>
    public List<double>? Rect { get; init; }
}

public sealed record SpecItem
{
    /// <summary>step, arrow, line, box, ellipse, highlight, text, pixelate, blur, redact, spotlight, magnify, image</summary>
    public string Type { get; init; } = "";
    public SpecAnchor? At { get; init; }
    public SpecAnchor? Around { get; init; }
    public SpecAnchor? From { get; init; }
    public SpecAnchor? To { get; init; }
    public string? Text { get; init; }
    public string? Label { get; init; }
    public int? Number { get; init; }
    public string? Pattern { get; init; }
    public string? Regex { get; init; }
    public string? Match { get; init; }
    public string? Color { get; init; }
    public double? Padding { get; init; }
    public double? Width { get; init; }
    public double? Size { get; init; }
    public double? Zoom { get; init; }
    public bool? Callout { get; init; }
    public bool? Filled { get; init; }
    public int? Heads { get; init; }
    /// <summary>Redaction: "blur" or "pixelate" (default).</summary>
    public string? Style { get; init; }
    /// <summary>image: a PNG file to place.</summary>
    public string? File { get; init; }

    [JsonIgnore] internal IEnumerable<SpecAnchor> Anchors => new[] { At, Around, From, To }.OfType<SpecAnchor>();
}
