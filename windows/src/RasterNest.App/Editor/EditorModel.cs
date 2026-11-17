using RasterNest.Core;
using RasterNest.Render;
using SkiaSharp;

namespace RasterNest.App.Editor;

public enum Tool { Select, Arrow, Line, Rectangle, Ellipse, Highlight, Text, Step, Pixelate, Spotlight, Magnify, Pen, Crop }

public static class Tools
{
    public static readonly Tool[] All = Enum.GetValues<Tool>();

    public static AnnotationKind? Kind(this Tool t) => t switch
    {
        Tool.Arrow => AnnotationKind.Arrow, Tool.Line => AnnotationKind.Line, Tool.Rectangle => AnnotationKind.Rectangle,
        Tool.Ellipse => AnnotationKind.Ellipse, Tool.Highlight => AnnotationKind.Highlight, Tool.Text => AnnotationKind.Text,
        Tool.Step => AnnotationKind.Step, Tool.Pixelate => AnnotationKind.Pixelate, Tool.Spotlight => AnnotationKind.Spotlight,
        Tool.Magnify => AnnotationKind.Magnify, Tool.Pen => AnnotationKind.Pen, _ => null,
    };

    public static Tool? FromKind(AnnotationKind k)
    {
        foreach (var t in All) if (t.Kind() == k) return t;
        return null;
    }

    public static string Title(this Tool t) => t switch
    {
        Tool.Highlight => "Highlighter", Tool.Step => "Step", Tool.Pixelate => "Pixelate or Blur", _ => t.ToString(),
    };

    /// <summary>Segoe Fluent Icons glyphs.</summary>
    public static string Glyph(this Tool t) => t switch
    {
        Tool.Select => "", Tool.Arrow => "", Tool.Line => "", Tool.Rectangle => "", Tool.Ellipse => "",
        Tool.Highlight => "", Tool.Text => "", Tool.Step => "", Tool.Pixelate => "", Tool.Spotlight => "",
        Tool.Magnify => "", Tool.Pen => "", Tool.Crop => "", _ => "",
    };

    public static char Shortcut(this Tool t) => t switch
    {
        Tool.Select => 'V', Tool.Arrow => 'A', Tool.Line => 'L', Tool.Rectangle => 'R', Tool.Ellipse => 'E', Tool.Highlight => 'H',
        Tool.Text => 'T', Tool.Step => 'N', Tool.Pixelate => 'B', Tool.Spotlight => 'S', Tool.Magnify => 'M', Tool.Pen => 'P',
        Tool.Crop => 'C', _ => ' ',
    };

    public static Dictionary<Tool, AnnotationStyle> DefaultStyles(double s) => new()
    {
        [Tool.Arrow] = new() { Color = Rgba.Red, LineWidth = 4 * s },
        [Tool.Line] = new() { Color = Rgba.Red, LineWidth = 4 * s },
        [Tool.Rectangle] = new() { Color = Rgba.Red, LineWidth = 3 * s },
        [Tool.Ellipse] = new() { Color = Rgba.Red, LineWidth = 3 * s },
        [Tool.Highlight] = new() { Color = Rgba.Yellow, LineWidth = 0, Shadow = false, Opacity = 0.45 },
        [Tool.Text] = new() { Color = Rgba.Red, FontSize = 20 * s, Shadow = false },
        [Tool.Step] = new() { Color = Rgba.Red, FontSize = 14 * s },
        [Tool.Pixelate] = new() { Color = Rgba.Black, LineWidth = 10 * s, Shadow = false },
        [Tool.Spotlight] = new() { Color = Rgba.Black, LineWidth = 0, Shadow = false, Opacity = 0.55 },
        [Tool.Magnify] = new() { Color = Rgba.White, LineWidth = 4 * s, Shadow = true, Zoom = 2 },
        [Tool.Pen] = new() { Color = Rgba.Red, LineWidth = 4 * s },
    };
}

/// <summary>Everything about one open capture: image, annotations, tool state and undo. A port of the Mac EditorModel.</summary>
public sealed class EditorModel : IDisposable
{
    public sealed record Snapshot(SKImage Image, List<Annotation> Annotations, CanvasEffects Effects);

    private Tool tool = Tool.Arrow;
    private readonly Stack<Snapshot> undo = new(), redo = new();
    private (string Key, DateTime Time)? lastCoalesce;
    private readonly HashSet<SKImage> retained = [];

    public SKImage Image { get; private set; }
    public List<Annotation> Annotations { get; private set; }
    public CanvasEffects Effects { get; private set; }
    public double PixelScale { get; }
    public Dictionary<Tool, AnnotationStyle> Styles { get; }
    public Guid? SelectedId { get; set; }
    public RectD? CropRect { get; set; }
    public bool IsDirty { get; private set; }

    /// <summary>Anything visible changed (redraw).</summary>
    public event Action? Changed;
    /// <summary>The tool, selection or inspected style changed (update the inspector).</summary>
    public event Action? InspectorChanged;

    public EditorModel(SKImage image, double pixelScale, IEnumerable<Annotation>? annotations = null, CanvasEffects? effects = null)
    {
        Image = image;
        retained.Add(image);
        PixelScale = Math.Max(1, pixelScale);
        Annotations = annotations?.ToList() ?? [];
        Effects = effects ?? CanvasEffects.None;
        Styles = Tools.DefaultStyles(PixelScale);
    }

    public Tool Tool
    {
        get => tool;
        set
        {
            tool = value;
            if (value != Tool.Crop) CropRect = null;
            InspectorChanged?.Invoke();
            Changed?.Invoke();
        }
    }

    public SizeD ImageSize => new(Image.Width, Image.Height);
    public RectD ImageBounds => new(0, 0, Image.Width, Image.Height);
    public Annotation? Selected => SelectedId is { } id ? Find(id) : null;
    public Annotation? Find(Guid id) => Annotations.FirstOrDefault(a => a.Id == id);
    public int NextStepNumber => Annotation.NextStepNumber(Annotations);
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;
    public AnnotationStyle StyleFor(Tool t) => Styles.TryGetValue(t, out var s) ? s with { } : new AnnotationStyle();

    public Snapshot Current => new(Image, Annotations.Select(a => a.Clone()).ToList(), Effects with { });

    public void Select(Guid? id)
    {
        SelectedId = id;
        InspectorChanged?.Invoke();
        Changed?.Invoke();
    }

    public void NotifyChanged() => Changed?.Invoke();

    // MARK: undo

    /// <summary>Records previous as an undo step. Calls with the same coalesce key within a second merge.</summary>
    public void RegisterUndo(Snapshot previous, string? coalesce = null)
    {
        if (coalesce != null && lastCoalesce is { } last && last.Key == coalesce && (DateTime.UtcNow - last.Time).TotalSeconds < 1)
        {
            lastCoalesce = (coalesce, DateTime.UtcNow);
            MarkChanged();
            return;
        }
        lastCoalesce = coalesce != null ? (coalesce, DateTime.UtcNow) : null;
        undo.Push(previous);
        retained.Add(previous.Image);
        if (undo.Count > 200) Trim();
        redo.Clear();
        MarkChanged();
    }

    /// <summary>Call before mutating.</summary>
    public void Checkpoint(string? coalesce = null) => RegisterUndo(Current, coalesce);

    public void Undo()
    {
        if (undo.Count == 0) return;
        redo.Push(Current);
        Restore(undo.Pop());
    }

    public void Redo()
    {
        if (redo.Count == 0) return;
        undo.Push(Current);
        Restore(redo.Pop());
    }

    private void Restore(Snapshot s)
    {
        Image = s.Image;
        Annotations = s.Annotations.Select(a => a.Clone()).ToList();
        Effects = s.Effects;
        if (SelectedId is { } id && Find(id) == null) SelectedId = null;
        CropRect = null;
        lastCoalesce = null;
        MarkChanged();
        InspectorChanged?.Invoke();
    }

    private void Trim()
    {
        var keep = undo.Take(200).Reverse().ToList();
        undo.Clear();
        foreach (var s in keep) undo.Push(s);
    }

    private void MarkChanged()
    {
        IsDirty = true;
        Changed?.Invoke();
    }

    public void MarkSaved() => IsDirty = false;

    // MARK: mutations

    public void Insert(Annotation a) { Annotations.Add(a); Changed?.Invoke(); }

    public void RemoveSilently(Guid id)
    {
        Annotations.RemoveAll(a => a.Id == id);
        if (SelectedId == id) SelectedId = null;
        Changed?.Invoke();
    }

    public void Update(Guid id, Action<Annotation> body)
    {
        if (Find(id) is not { } a) return;
        body(a);
        if (a.Kind == AnnotationKind.Text) TextMetrics.Layout(a);
        Changed?.Invoke();
    }

    /// <summary>Places a picture as a movable, resizable layer (with undo) and selects it.</summary>
    public Annotation AddImageLayer(byte[] png, SizeD pixelSize, double scale, PointD? center = null)
    {
        var pre = Current;
        var w = pixelSize.Width * PixelScale / Math.Max(scale, 1);
        var h = pixelSize.Height * PixelScale / Math.Max(scale, 1);
        // Start no bigger than 60% of the capture; corner handles resize it from there.
        var fit = Math.Min(1, Math.Min(ImageSize.Width * 0.6 / w, ImageSize.Height * 0.6 / h));
        w = Math.Round(w * fit); h = Math.Round(h * fit);
        var c = center ?? new PointD(ImageSize.Width / 2, ImageSize.Height / 2);
        c = new PointD(Math.Clamp(c.X, w / 2, Math.Max(w / 2, ImageSize.Width - w / 2)), Math.Clamp(c.Y, h / 2, Math.Max(h / 2, ImageSize.Height - h / 2)));
        var layer = Annotation.ImageLayer(png, c, new SizeD(w, h), new AnnotationStyle { Color = Rgba.White, LineWidth = 0, Shadow = true, Opacity = 1 });
        Annotations.Add(layer);
        SelectedId = layer.Id;
        tool = Tool.Select;
        RegisterUndo(pre);
        InspectorChanged?.Invoke();
        return layer;
    }

    public void DeleteSelected()
    {
        if (SelectedId is not { } id) return;
        Checkpoint();
        RemoveSilently(id);
        InspectorChanged?.Invoke();
    }

    public void DuplicateSelected()
    {
        if (Selected is not { } sel) return;
        Checkpoint();
        var copy = sel.Clone();
        copy.Id = Guid.NewGuid();
        copy.Translate(12 * PixelScale, 12 * PixelScale);
        if (copy.Kind == AnnotationKind.Step) copy.Number = NextStepNumber;
        Annotations.Add(copy);
        Select(copy.Id);
    }

    /// <summary>Moves an annotation to the top without its own undo step (the drag that caused it records one).</summary>
    public void RaiseSilently(Guid id)
    {
        var i = Annotations.FindIndex(a => a.Id == id);
        if (i < 0 || i == Annotations.Count - 1) return;
        var a = Annotations[i];
        Annotations.RemoveAt(i);
        Annotations.Add(a);
    }

    public void BringSelectedToFront()
    {
        if (Selected is not { } a) return;
        Checkpoint();
        Annotations.Remove(a);
        Annotations.Add(a);
        Changed?.Invoke();
    }

    public void SendSelectedToBack()
    {
        if (Selected is not { } a) return;
        Checkpoint();
        Annotations.Remove(a);
        Annotations.Insert(0, a);
        Changed?.Invoke();
    }

    public void NudgeSelected(double dx, double dy)
    {
        if (SelectedId is not { } id) return;
        Checkpoint($"nudge-{id}");
        Update(id, a => a.Translate(dx, dy));
    }

    public void ApplyCrop()
    {
        if (CropRect is not { } c) return;
        var r = c.Integral.Intersect(ImageBounds);
        if (r.IsNull || r.Width < 2 || r.Height < 2) { CropRect = null; Changed?.Invoke(); return; }
        Checkpoint();
        var cropped = Image.Subset(new SKRectI((int)r.MinX, (int)r.MinY, (int)r.MaxX, (int)r.MaxY));
        if (cropped == null) return;
        SetImage(cropped);
        foreach (var a in Annotations) a.Translate(-r.MinX, -r.MinY);
        CropRect = null;
        Tool = Tool.Select;
    }

    public void SetSelectedNumber(int n)
    {
        if (Selected is not { Kind: AnnotationKind.Image } sel) return;
        Checkpoint($"number-{sel.Id}");
        Update(sel.Id, a => a.Number = Math.Max(0, n));
    }

    private void SetImage(SKImage image)
    {
        Image = image;
        retained.Add(image);
        Changed?.Invoke();
    }

    // MARK: canvas size

    /// <summary>Re-frames the canvas to rect: bigger adds blank space, smaller trims. No undo step of its own.</summary>
    public void SetCanvasSilently(RectD rect)
    {
        var r = rect.Integral;
        if (r.Width < 8 || r.Height < 8 || r.Width > 16_384 || r.Height > 16_384 || r == ImageBounds) return;
        using var surface = SKSurface.Create(new SKImageInfo((int)r.Width, (int)r.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        surface.Canvas.Clear(BackgroundColor(Image) ?? SKColors.Transparent);
        surface.Canvas.DrawImage(Image, (float)-r.MinX, (float)-r.MinY);
        SetImage(surface.Snapshot());
        foreach (var a in Annotations) a.Translate(-r.MinX, -r.MinY);
    }

    /// <summary>Grows the canvas (with a margin) so the layer is fully on it. Returns true if it grew.</summary>
    public bool GrowCanvas(Guid id)
    {
        if (Find(id) is not { } a) return false;
        var bounds = ImageBounds;
        var r = a.Rect;
        if (bounds.Contains(r)) return false;
        var margin = 24 * PixelScale;
        double minX = Math.Min(bounds.MinX, r.MinX - (r.MinX < bounds.MinX ? margin : 0));
        double minY = Math.Min(bounds.MinY, r.MinY - (r.MinY < bounds.MinY ? margin : 0));
        double maxX = Math.Max(bounds.MaxX, r.MaxX + (r.MaxX > bounds.MaxX ? margin : 0));
        double maxY = Math.Max(bounds.MaxY, r.MaxY + (r.MaxY > bounds.MaxY ? margin : 0));
        SetCanvasSilently(new RectD(minX, minY, maxX - minX, maxY - minY));
        return true;
    }

    /// <summary>Trims (or grows) the canvas to the picture's content and every annotation, plus a margin.</summary>
    public void FitCanvasToContent()
    {
        RectD content = ContentBounds(Image) ?? RectD.Null;
        foreach (var a in Annotations.Where(a => a.Kind != AnnotationKind.Spotlight)) content = content.Union(a.Bounds);
        if (content.IsNull || content.Width <= 0) return;
        var pre = Current;
        var margin = 24 * PixelScale;
        SetCanvasSilently(content.Inset(-margin, -margin));
        if (!ReferenceEquals(pre.Image, Image)) RegisterUndo(pre);
    }

    /// <summary>The colour to extend the canvas with: the picture's top-left pixel (null when it's transparent).</summary>
    public static SKColor? BackgroundColor(SKImage image)
    {
        using var px = new SKBitmap(1, 1, SKColorType.Bgra8888, SKAlphaType.Unpremul);
        if (!image.ReadPixels(px.Info, px.GetPixels(), px.RowBytes, 0, 0)) return SKColors.White;
        var c = px.GetPixel(0, 0);
        return c.Alpha <= 8 ? null : c;
    }

    /// <summary>Bounding box of pixels that differ from the top-left (background) pixel.</summary>
    public static RectD? ContentBounds(SKImage image)
    {
        var k = Math.Min(1, 1200.0 / Math.Max(image.Width, image.Height));
        int w = Math.Max(1, (int)(image.Width * k)), h = Math.Max(1, (int)(image.Height * k));
        using var small = new SKBitmap(w, h, SKColorType.Bgra8888, SKAlphaType.Premul);
        using (var c = new SKCanvas(small)) c.DrawImage(image, new SKRect(0, 0, w, h), new SKSamplingOptions(SKFilterMode.Nearest));
        var bg = small.GetPixel(0, 0);
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var p = small.GetPixel(x, y);
                if (Math.Abs(p.Red - bg.Red) + Math.Abs(p.Green - bg.Green) + Math.Abs(p.Blue - bg.Blue) + Math.Abs(p.Alpha - bg.Alpha) <= 24) continue;
                minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
            }
        if (maxX < 0) return null;
        var f = image.Width / (double)w;
        return new RectD(minX * f, minY * f, (maxX - minX + 1) * f, (maxY - minY + 1) * f).Integral;
    }

    // MARK: frame

    public void UpdateEffects(string coalesce, Func<CanvasEffects, CanvasEffects> body)
    {
        Checkpoint($"effects-{coalesce}");
        Effects = body(Effects);
        Changed?.Invoke();
    }

    // MARK: inspector

    /// <summary>The kind whose properties the inspector shows: the selection, else the current tool.</summary>
    public AnnotationKind? InspectedKind => Selected?.Kind ?? Tool.Kind();
    public AnnotationStyle InspectedStyle => Selected?.Style ?? StyleFor(Tool);

    /// <summary>Edits the selection's style (with undo) and remembers it as that tool's default.</summary>
    public void UpdateInspectedStyle(string coalesce, Action<AnnotationStyle> body)
    {
        if (Selected is { } sel)
        {
            Checkpoint($"style-{coalesce}-{sel.Id}");
            var style = sel.Style with { };
            body(style);
            Update(sel.Id, a => a.Style = style);
            if (Tools.FromKind(sel.Kind) is { } t) Styles[t] = style with { };
        }
        else
        {
            var style = StyleFor(Tool);
            body(style);
            Styles[Tool] = style;
        }
        // No InspectorChanged here: rebuilding the panel mid-click or mid-drag swallowed the input.
        // Callers that change what the panel shows (colour highlight, pixelate/blur) refresh it themselves.
    }

    // MARK: output

    public SKImage Flattened() => new AnnotationRenderer(PixelScale).Flatten(Image, Annotations, Effects);

    public NestDocument MakeDocument()
    {
        var png = ImageCodec.Encode(Image, ExportFormat.Png, PixelScale);
        return new NestDocument(png, PixelScale, Annotations.Select(a => a.Clone()), Effects.IsEmpty ? null : Effects);
    }

    public void Dispose()
    {
        foreach (var img in retained) img.Dispose();
        retained.Clear();
    }
}
