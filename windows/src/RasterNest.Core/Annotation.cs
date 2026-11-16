using System.Text.Json.Serialization;

namespace RasterNest.Core;

[JsonConverter(typeof(JsonStringEnumConverter<AnnotationKind>))]
public enum AnnotationKind
{
    [JsonStringEnumMemberName("arrow")] Arrow,
    [JsonStringEnumMemberName("line")] Line,
    [JsonStringEnumMemberName("rectangle")] Rectangle,
    [JsonStringEnumMemberName("ellipse")] Ellipse,
    [JsonStringEnumMemberName("highlight")] Highlight,
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("step")] Step,
    [JsonStringEnumMemberName("pixelate")] Pixelate,
    [JsonStringEnumMemberName("spotlight")] Spotlight,
    [JsonStringEnumMemberName("pen")] Pen,
    [JsonStringEnumMemberName("magnify")] Magnify,
    /// <summary>A picture placed on top of the capture (picture-in-picture, before/after, logos).</summary>
    [JsonStringEnumMemberName("image")] Image,
}

public static class AnnotationKindExtensions
{
    /// <summary>Kinds whose geometry is the rectangle spanned by start and end.</summary>
    public static bool IsBoxed(this AnnotationKind k) => k switch
    {
        AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Highlight or AnnotationKind.Pixelate
            or AnnotationKind.Spotlight or AnnotationKind.Text or AnnotationKind.Magnify or AnnotationKind.Image => true,
        _ => false,
    };
}

/// <summary>How an annotation is drawn. Sizes are in image pixels.</summary>
public sealed record AnnotationStyle
{
    /// <summary>Main color: stroke for shapes, text color, fill for steps and callouts.</summary>
    public Rgba Color { get; set; } = Rgba.Red;
    /// <summary>Stroke width in image pixels. For pixelate this is the block size.</summary>
    public double LineWidth { get; set; } = 4;
    /// <summary>Font size in image pixels (text and step numbers).</summary>
    public double FontSize { get; set; } = 22;
    /// <summary>Shapes get a translucent fill; text becomes a filled callout.</summary>
    public bool Filled { get; set; }
    public bool Shadow { get; set; } = true;
    /// <summary>Highlighter opacity / spotlight dim amount.</summary>
    public double Opacity { get; set; } = 1;
    /// <summary>Magnification for the magnify lens (2 = 200%).</summary>
    public double? Zoom { get; set; }
    /// <summary>Pixelate tool: a Gaussian blur instead of blocks.</summary>
    public bool? Blur { get; set; }
    /// <summary>Arrows: 2 draws a head at both ends.</summary>
    public int? Heads { get; set; }

    [JsonIgnore] public bool IsBlur => Blur == true;
    [JsonIgnore] public bool IsDoubleHeaded => (Heads ?? 1) >= 2;
    [JsonIgnore] public double ZoomFactor => Math.Max(1.2, Math.Min(Zoom ?? 2, 6));

    public static AnnotationStyle Standard => new();
}

/// <summary>A single markup object. All coordinates are in image pixels, origin top-left, y down.</summary>
public sealed class Annotation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public AnnotationKind Kind { get; set; }
    public PointD Start { get; set; }
    public PointD End { get; set; }
    /// <summary>Freehand points (pen only).</summary>
    public List<PointD> Points { get; set; } = [];
    public string Text { get; set; } = "";
    /// <summary>Step number (step only).</summary>
    public int Number { get; set; }
    public AnnotationStyle Style { get; set; } = new();
    /// <summary>The picture for image layers (PNG). Absent for every other kind.</summary>
    [JsonPropertyName("imagePNG")]
    public byte[]? ImagePng { get; set; }

    public Annotation() { }

    public Annotation(AnnotationKind kind, PointD start, PointD? end = null, IEnumerable<PointD>? points = null,
                      string text = "", int number = 0, AnnotationStyle? style = null, byte[]? imagePng = null, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Kind = kind;
        Start = start;
        End = end ?? start;
        Points = points?.ToList() ?? [];
        Text = text;
        Number = number;
        Style = style ?? new AnnotationStyle();
        ImagePng = imagePng;
    }

    /// <summary>A deep copy (same id) for undo snapshots.</summary>
    public Annotation Clone() => new()
    {
        Id = Id, Kind = Kind, Start = Start, End = End, Points = [.. Points], Text = Text, Number = Number,
        Style = Style with { }, ImagePng = ImagePng,
    };

    [JsonIgnore] public RectD Rect => Geometry.Rect(Start, End);

    [JsonIgnore] public double StepRadius => Math.Max(Style.FontSize * 0.85, 8);

    /// <summary>Visual bounds, used for selection outlines.</summary>
    [JsonIgnore]
    public RectD Bounds
    {
        get
        {
            var pad = Style.LineWidth / 2 + 1;
            switch (Kind)
            {
                case AnnotationKind.Pen:
                    return Geometry.BoundingBox(Points).Inset(-pad, -pad);
                case AnnotationKind.Step:
                    var r = StepRadius;
                    return new RectD(Start.X - r, Start.Y - r, r * 2, r * 2);
                case AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Rectangle or AnnotationKind.Ellipse
                    or AnnotationKind.Magnify or AnnotationKind.Image:
                    return Rect.Inset(-pad, -pad);
                default:
                    return Rect;
            }
        }
    }

    /// <summary>True when the annotation is too small to be meaningful (e.g. a click without a drag).</summary>
    [JsonIgnore]
    public bool IsDegenerate => Kind switch
    {
        AnnotationKind.Pen => Points.Count < 2,
        AnnotationKind.Step or AnnotationKind.Text => false,
        _ => Math.Abs(End.X - Start.X) < 3 && Math.Abs(End.Y - Start.Y) < 3,
    };

    public bool HitTest(PointD p, double tolerance = 4)
    {
        var tol = tolerance + Style.LineWidth / 2;
        switch (Kind)
        {
            case AnnotationKind.Arrow or AnnotationKind.Line:
                return Geometry.DistanceToSegment(p, Start, End) <= tol;
            case AnnotationKind.Pen:
                if (Points.Count <= 1) return Points.Count == 1 && Geometry.Distance(p, Points[0]) <= tol;
                for (var i = 1; i < Points.Count; i++)
                    if (Geometry.DistanceToSegment(p, Points[i - 1], Points[i]) <= tol) return true;
                return false;
            case AnnotationKind.Rectangle:
            {
                var outer = Rect.Inset(-tol, -tol);
                if (!outer.Contains(p)) return false;
                if (Style.Filled) return true;
                var inner = Rect.Inset(tol, tol);
                return inner.IsNull || inner.IsEmpty || !inner.Contains(p);
            }
            case AnnotationKind.Ellipse:
            {
                var r = Rect;
                double rx = r.Width / 2, ry = r.Height / 2;
                if (rx <= 0.5 || ry <= 0.5) return r.Inset(-tol, -tol).Contains(p);
                double dx = (p.X - r.MidX) / rx, dy = (p.Y - r.MidY) / ry;
                var v = Math.Sqrt(dx * dx + dy * dy);
                if (Style.Filled && v <= 1) return true;
                return Math.Abs(v - 1) * Math.Min(rx, ry) <= tol;
            }
            case AnnotationKind.Step:
                return Geometry.Distance(p, Start) <= StepRadius + tolerance;
            default:
                return Rect.Inset(-tolerance, -tolerance).Contains(p);
        }
    }

    public void Translate(double dx, double dy)
    {
        Start = Start.Offset(dx, dy);
        End = End.Offset(dx, dy);
        for (var i = 0; i < Points.Count; i++) Points[i] = Points[i].Offset(dx, dy);
    }

    /// <summary>Draggable handles. Lines/arrows: [start, end]. Boxes: four corners.</summary>
    [JsonIgnore]
    public IReadOnlyList<PointD> Handles => Kind switch
    {
        AnnotationKind.Arrow or AnnotationKind.Line => [Start, End],
        AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Highlight or AnnotationKind.Pixelate
            or AnnotationKind.Spotlight or AnnotationKind.Magnify or AnnotationKind.Image =>
            [Start, End, new PointD(Start.X, End.Y), new PointD(End.X, Start.Y)],
        _ => [],
    };

    public void MoveHandle(int index, PointD p)
    {
        if (Kind == AnnotationKind.Image && ImageAspect is { } aspect && index <= 3)
        {
            MoveImageCorner(index, p, aspect);
            return;
        }
        switch (index)
        {
            case 0: Start = p; break;
            case 1: End = p; break;
            case 2: Start = Start with { X = p.X }; End = End with { Y = p.Y }; break;
            case 3: End = End with { X = p.X }; Start = Start with { Y = p.Y }; break;
        }
    }

    /// <summary>Width ÷ height of an image layer's picture.</summary>
    [JsonIgnore]
    public double? ImageAspect =>
        ImagePng is { } data && PngInfo.Read(data) is { Height: > 0 } info ? (double)info.Width / info.Height : null;

    /// <summary>Image layers resize from a corner and keep their proportions; the opposite corner stays put.</summary>
    private void MoveImageCorner(int index, PointD p, double aspect)
    {
        var corners = Handles;
        var opposite = corners[new[] { 1, 0, 3, 2 }[index]];
        double w = Math.Abs(p.X - opposite.X), h = Math.Abs(p.Y - opposite.Y);
        // Follow whichever direction the pointer moved further, proportionally.
        if (w / Math.Max(h, 0.0001) > aspect) h = w / aspect; else w = h * aspect;
        w = Math.Max(w, 8);
        h = Math.Max(h, 8 / aspect);
        double sx = p.X >= opposite.X ? 1 : -1, sy = p.Y >= opposite.Y ? 1 : -1;
        var moved = new PointD(opposite.X + sx * w, opposite.Y + sy * h);
        Start = new PointD(Math.Min(opposite.X, moved.X), Math.Min(opposite.Y, moved.Y));
        End = new PointD(Math.Max(opposite.X, moved.X), Math.Max(opposite.Y, moved.Y));
    }

    /// <summary>An image layer of <paramref name="png"/>, <paramref name="size"/> big (pixels), centered on <paramref name="center"/>.</summary>
    public static Annotation ImageLayer(byte[] png, PointD center, SizeD size, AnnotationStyle style)
    {
        var origin = new PointD(center.X - size.Width / 2, center.Y - size.Height / 2);
        return new Annotation(AnnotationKind.Image, origin, new PointD(origin.X + size.Width, origin.Y + size.Height),
                              style: style, imagePng: png);
    }

    /// <summary>Next number for the step tool: one more than the highest existing step.</summary>
    public static int NextStepNumber(IEnumerable<Annotation> annotations) =>
        annotations.Where(a => a.Kind == AnnotationKind.Step).Select(a => a.Number).DefaultIfEmpty(0).Max() + 1;
}
