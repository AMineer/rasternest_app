using RasterNest.Core;
using SkiaSharp;

namespace RasterNest.Render;

public static class SkiaExtensions
{
    public static SKColor ToSK(this Rgba c) =>
        new((byte)Math.Round(Math.Clamp(c.R, 0, 1) * 255), (byte)Math.Round(Math.Clamp(c.G, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(c.B, 0, 1) * 255), (byte)Math.Round(Math.Clamp(c.A, 0, 1) * 255));

    public static SKPoint ToSK(this PointD p) => new((float)p.X, (float)p.Y);
    public static SKRect ToSK(this RectD r) => new((float)r.MinX, (float)r.MinY, (float)r.MaxX, (float)r.MaxY);
    public static RectD ToRectD(this SKRect r) => new(r.Left, r.Top, r.Width, r.Height);
}

/// <summary>Text sizing shared by the renderer and the editor's inline text box.</summary>
public static class TextMetrics
{
    private static readonly SKTypeface Regular = Load(SKFontStyleWeight.SemiBold);
    private static readonly SKTypeface Bold = Load(SKFontStyleWeight.Bold);

    private static SKTypeface Load(SKFontStyleWeight weight)
    {
        foreach (var family in new[] { "Segoe UI Variable Text", "Segoe UI", "Helvetica Neue", "Arial" })
        {
            var t = SKTypeface.FromFamilyName(family, weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
            if (t != null && t.FamilyName.StartsWith(family.Split(' ')[0], StringComparison.OrdinalIgnoreCase)) return t;
        }
        return SKTypeface.FromFamilyName(null, weight, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright) ?? SKTypeface.Default;
    }

    public static SKFont Font(Annotation a) => new(Regular, (float)a.Style.FontSize) { Subpixel = true, Edging = SKFontEdging.Antialias };
    public static SKFont BoldFont(double size) => new(Bold, (float)size) { Subpixel = true, Edging = SKFontEdging.Antialias };

    public static double Padding(Annotation a) => a.Style.Filled ? a.Style.FontSize * 0.45 : 0;

    public static SKColor TextColor(Annotation a)
    {
        if (!a.Style.Filled) return a.Style.Color.ToSK();
        return a.Style.Color.PrefersDarkText ? SKColors.Black : SKColors.White;
    }

    public static string[] Lines(string text) => (text.Length == 0 ? " " : text).Replace("\r\n", "\n").Split('\n');

    public static SizeD TextSize(string text, Annotation a)
    {
        using var font = Font(a);
        var lines = Lines(text);
        var width = lines.Max(l => font.MeasureText(l.Length == 0 ? " " : l));
        var height = font.Spacing * lines.Length;
        return new SizeD(Math.Max(Math.Ceiling(width), a.Style.FontSize * 0.5), Math.Ceiling(height));
    }

    /// <summary>Sets End so that Rect wraps the text plus callout padding.</summary>
    public static void Layout(Annotation a)
    {
        var size = TextSize(a.Text, a);
        var p = Padding(a);
        a.End = new PointD(a.Start.X + size.Width + p * 2, a.Start.Y + size.Height + p * 2);
    }
}

/// <summary>
/// Draws a base image plus annotations onto a Skia canvas measured in image pixels (y down).
/// Used for the editor canvas, clipboard/export flattening and <c>rnest export</c>.
/// </summary>
public sealed class AnnotationRenderer(double unit = 1)
{
    /// <summary>Pixel scale of the image (2 for Retina, 1.5 for 150%); sizes shadows and details consistently.</summary>
    public double Unit { get; set; } = unit;

    private readonly Dictionary<int, SKImage> effectCache = [];
    private SKImage? cacheSource;
    private readonly Dictionary<Guid, (byte[] Data, SKImage Image)> layerCache = [];

    private float U(double v) => (float)(v * Unit);

    /// <summary>
    /// Renders everything in image coordinates. With effects, the frame is drawn around the image,
    /// extending to negative coordinates by effects.Padding.
    /// </summary>
    public void Render(SKCanvas canvas, SKImage baseImage, IReadOnlyList<Annotation> annotations, CanvasEffects? effects = null,
                       Guid? textHiddenFor = null)
    {
        effects ??= CanvasEffects.None;
        var full = new SKRect(0, 0, baseImage.Width, baseImage.Height);
        var radius = (float)Math.Min(effects.CornerRadius, Math.Min(full.Width / 2, full.Height / 2));
        using var imagePath = new SKPath();
        imagePath.AddRoundRect(full, radius, radius);

        if (effects.Padding > 0 && effects.Background != FrameBackground.None)
        {
            var outer = SKRect.Inflate(full, (float)effects.Padding, (float)effects.Padding);
            using var paint = new SKPaint { IsAntialias = true };
            if (effects.Background == FrameBackground.Gradient)
                paint.Shader = SKShader.CreateLinearGradient(new SKPoint(outer.Left, outer.Top), new SKPoint(outer.Right, outer.Bottom),
                    [effects.BackgroundColor.ToSK(), effects.BackgroundColor2.ToSK()], [0, 1], SKShaderTileMode.Clamp);
            else
                paint.Color = effects.BackgroundColor.ToSK();
            canvas.DrawRect(outer, paint);
        }

        if (effects.Shadow)
        {
            using var paint = new SKPaint
            {
                IsAntialias = true, Color = SKColors.White,
                ImageFilter = SKImageFilter.CreateDropShadow(0, U(10), U(14), U(14), new SKColor(0, 0, 0, 89)),
            };
            canvas.DrawPath(imagePath, paint);
        }

        canvas.Save();
        if (radius > 0) canvas.ClipPath(imagePath, antialias: true);
        canvas.DrawImage(baseImage, 0, 0);
        var spotlights = annotations.Where(a => a.Kind == AnnotationKind.Spotlight).ToList();
        if (spotlights.Count > 0) DrawSpotlights(canvas, spotlights, full);
        canvas.Restore();

        if (effects.BorderWidth > 0)
        {
            var bw = (float)effects.BorderWidth;
            using var paint = new SKPaint { IsAntialias = true, IsStroke = true, StrokeWidth = bw, Color = effects.BorderColor.ToSK() };
            var r = Math.Max(0, radius - bw / 2);
            canvas.DrawRoundRect(SKRect.Inflate(full, -bw / 2, -bw / 2), r, r, paint);
        }

        for (var i = 0; i < annotations.Count; i++)
        {
            var a = annotations[i];
            if (a.Kind == AnnotationKind.Spotlight) continue;
            if (a.Kind == AnnotationKind.Magnify) DrawMagnifier(canvas, a, baseImage, full, annotations.Take(i).ToList());
            else Draw(canvas, a, baseImage, full, a.Id == textHiddenFor);
        }
    }

    /// <summary>A new image with the annotations (and frame, if any) burned in.</summary>
    public SKImage Flatten(SKImage image, IReadOnlyList<Annotation> annotations, CanvasEffects? effects = null)
    {
        effects ??= CanvasEffects.None;
        var size = effects.OutputSize(new SizeD(image.Width, image.Height));
        int w = (int)Math.Round(size.Width), h = (int)Math.Round(size.Height);
        using var surface = SKSurface.Create(new SKImageInfo(Math.Max(1, w), Math.Max(1, h), SKImageInfo.PlatformColorType, SKAlphaType.Premul))
            ?? throw new InvalidOperationException("Couldn't create a drawing surface.");
        surface.Canvas.Clear(SKColors.Transparent);
        surface.Canvas.Translate((float)effects.Padding, (float)effects.Padding);
        Render(surface.Canvas, image, annotations, effects);
        return surface.Snapshot();
    }

    public SKImage Flatten(SKBitmap bitmap, IReadOnlyList<Annotation> annotations, CanvasEffects? effects = null)
    {
        using var image = SKImage.FromBitmap(bitmap);
        return Flatten(image, annotations, effects);
    }

    // MARK: drawing

    private sealed class Restorer(SKCanvas canvas, int count) : IDisposable
    {
        public void Dispose() => canvas.RestoreToCount(count);
    }

    /// <summary>A layer whose contents get the standard annotation drop shadow (when the style asks for one).</summary>
    private IDisposable ShadowLayer(SKCanvas canvas, Annotation a)
    {
        if (!a.Style.Shadow) return new Restorer(canvas, canvas.Save());
        using var paint = new SKPaint { ImageFilter = SKImageFilter.CreateDropShadow(0, U(1.5), U(2), U(2), new SKColor(0, 0, 0, 115)) };
        return new Restorer(canvas, canvas.SaveLayer(paint));
    }

    private static SKPaint Stroke(SKColor color, double width, SKStrokeCap cap = SKStrokeCap.Butt, SKStrokeJoin join = SKStrokeJoin.Miter) =>
        new() { IsAntialias = true, IsStroke = true, Color = color, StrokeWidth = (float)width, StrokeCap = cap, StrokeJoin = join };

    private static SKPaint Fill(SKColor color) => new() { IsAntialias = true, Color = color };

    private void Draw(SKCanvas canvas, Annotation a, SKImage baseImage, SKRect full, bool hideText)
    {
        var color = a.Style.Color.ToSK();
        switch (a.Kind)
        {
            case AnnotationKind.Arrow:
            {
                using var _ = ShadowLayer(canvas, a);
                var lw = a.Style.LineWidth;
                var twoHeads = a.Style.IsDoubleHeaded;
                // With two heads, each may use at most half the shaft.
                var mid = Geometry.Midpoint(a.Start, a.End);
                var head = Geometry.ArrowHeadFor(twoHeads ? mid : a.Start, a.End, lw);
                ArrowHead? tail = twoHeads ? Geometry.ArrowHeadFor(mid, a.Start, lw) : null;
                using (var shaft = Stroke(color, lw, SKStrokeCap.Round))
                    canvas.DrawLine((tail?.Base ?? a.Start).ToSK(), head.Base.ToSK(), shaft);
                using var fill = Fill(color);
                using var outline = Stroke(color, lw, SKStrokeCap.Butt, SKStrokeJoin.Round);
                foreach (var h in tail is { } t ? new[] { head, t } : [head])
                {
                    using var path = new SKPath();
                    path.MoveTo(h.Tip.ToSK()); path.LineTo(h.Left.ToSK()); path.LineTo(h.Right.ToSK()); path.Close();
                    canvas.DrawPath(path, fill);
                    canvas.DrawPath(path, outline);
                }
                break;
            }
            case AnnotationKind.Line:
            {
                using var _ = ShadowLayer(canvas, a);
                using var p = Stroke(color, a.Style.LineWidth, SKStrokeCap.Round);
                canvas.DrawLine(a.Start.ToSK(), a.End.ToSK(), p);
                break;
            }
            case AnnotationKind.Rectangle or AnnotationKind.Ellipse:
            {
                using var _ = ShadowLayer(canvas, a);
                var r = a.Rect.ToSK();
                if (a.Style.Filled)
                {
                    using var f = Fill(a.Style.Color.WithAlpha(0.25).ToSK());
                    if (a.Kind == AnnotationKind.Rectangle) canvas.DrawRect(r, f); else canvas.DrawOval(r, f);
                }
                using var s = Stroke(color, a.Style.LineWidth, join: SKStrokeJoin.Round);
                if (a.Kind == AnnotationKind.Rectangle) canvas.DrawRect(r, s); else canvas.DrawOval(r, s);
                break;
            }
            case AnnotationKind.Highlight:
            {
                // Normal blending stays visible on dark screenshots (multiply vanishes there).
                using var f = new SKPaint { Color = a.Style.Color.WithAlpha(a.Style.Opacity).ToSK() };
                canvas.DrawRect(a.Rect.ToSK(), f);
                break;
            }
            case AnnotationKind.Pixelate:
            {
                var hidden = a.Style.IsBlur ? Blurred(baseImage, a.Style.LineWidth) : Pixelated(baseImage, a.Style.LineWidth);
                if (hidden == null) return;
                canvas.Save();
                canvas.ClipRect(a.Rect.ToSK());
                canvas.DrawImage(hidden, full);
                canvas.Restore();
                break;
            }
            case AnnotationKind.Spotlight:
                break; // drawn together in DrawSpotlights
            case AnnotationKind.Image:
                DrawImageLayer(canvas, a, color);
                break;
            case AnnotationKind.Magnify:
                DrawMagnifier(canvas, a, baseImage, full, []);
                break;
            case AnnotationKind.Pen:
            {
                var pts = a.Points;
                if (pts.Count < 2) return;
                using var _ = ShadowLayer(canvas, a);
                using var path = new SKPath();
                path.MoveTo(pts[0].ToSK());
                for (var i = 1; i < pts.Count; i++) path.QuadTo(pts[i - 1].ToSK(), Geometry.Midpoint(pts[i - 1], pts[i]).ToSK());
                path.LineTo(pts[^1].ToSK());
                using var p = Stroke(color, a.Style.LineWidth, SKStrokeCap.Round, SKStrokeJoin.Round);
                canvas.DrawPath(path, p);
                break;
            }
            case AnnotationKind.Step:
                DrawStep(canvas, a);
                break;
            case AnnotationKind.Text:
                DrawText(canvas, a, hideText);
                break;
        }
    }

    private void DrawImageLayer(SKCanvas canvas, Annotation a, SKColor color)
    {
        if (LayerImage(a) is not { } picture) return;
        var r = a.Rect.ToSK();
        var radius = (float)Math.Min(a.Style.LineWidth > 0 ? 6 * Unit : 4 * Unit, Math.Min(r.Width / 4, r.Height / 4));
        using var path = new SKPath();
        path.AddRoundRect(r, radius, radius);
        if (a.Style.Shadow)
        {
            using var sp = new SKPaint
            {
                IsAntialias = true, Color = SKColors.White,
                ImageFilter = SKImageFilter.CreateDropShadow(0, U(6), U(9), U(9), new SKColor(0, 0, 0, 102)),
            };
            canvas.DrawPath(path, sp);
        }
        canvas.Save();
        canvas.ClipPath(path, antialias: true);
        using (var ip = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(Math.Clamp(a.Style.Opacity, 0.05, 1) * 255)) })
            canvas.DrawImage(picture, r, new SKSamplingOptions(SKCubicResampler.Mitchell), ip);
        canvas.Restore();
        if (a.Style.LineWidth > 0)
        {
            var lw = (float)a.Style.LineWidth;
            using var s = Stroke(color, lw);
            var rr = Math.Max(0, radius - lw / 2);
            canvas.DrawRoundRect(SKRect.Inflate(r, -lw / 2, -lw / 2), rr, rr, s);
        }
        if (a.Number > 0)
        {
            // A step badge in the picture's top-left corner that travels with it.
            var badgeR = Math.Max(12 * Unit, Math.Min(26 * Unit, Math.Min(r.Width, r.Height) * 0.09));
            var inset = badgeR + 6 * Unit;
            var badge = new Annotation(AnnotationKind.Step, new PointD(r.Left + inset, r.Top + inset), number: a.Number,
                style: new AnnotationStyle { Color = a.Style.Color == Rgba.White ? Rgba.Red : a.Style.Color, FontSize = badgeR / 0.85, Shadow = true },
                id: a.Id);
            DrawStep(canvas, badge);
        }
    }

    /// <summary>A lens showing the area under it enlarged by Style.ZoomFactor.</summary>
    private void DrawMagnifier(SKCanvas canvas, Annotation a, SKImage baseImage, SKRect full, IReadOnlyList<Annotation> below)
    {
        var r = a.Rect.ToSK();
        if (r.Width <= 2 || r.Height <= 2) return;
        using var lens = new SKPath();
        if (a.Style.Filled)
        {
            var c = Math.Min(r.Width, r.Height) * 0.12f;
            lens.AddRoundRect(r, c, c);
        }
        else lens.AddOval(r);
        var zoom = (float)a.Style.ZoomFactor;

        using (ShadowLayer(canvas, a))
        using (var white = Fill(SKColors.White))
            canvas.DrawPath(lens, white);

        canvas.Save();
        canvas.ClipPath(lens, antialias: true);
        var dest = SKRect.Create(r.MidX - r.MidX * zoom, r.MidY - r.MidY * zoom, full.Width * zoom, full.Height * zoom);
        canvas.DrawImage(baseImage, dest, new SKSamplingOptions(SKCubicResampler.Mitchell));
        if (below.Count > 0)
        {
            canvas.Translate(dest.Left, dest.Top);
            canvas.Scale(zoom);
            foreach (var b in below)
                if (b.Kind is not (AnnotationKind.Magnify or AnnotationKind.Spotlight)) Draw(canvas, b, baseImage, full, false);
        }
        canvas.Restore();

        using var rim = Stroke(a.Style.Color.ToSK(), Math.Max(1, a.Style.LineWidth));
        canvas.DrawPath(lens, rim);
    }

    private void DrawStep(SKCanvas canvas, Annotation a)
    {
        var r = (float)a.StepRadius;
        var c = a.Start.ToSK();
        using (ShadowLayer(canvas, a))
        using (var f = Fill(a.Style.Color.ToSK()))
            canvas.DrawCircle(c, r, f);
        var ring = (float)Math.Max(1.5 * Unit, r * 0.1);
        using (var s = Stroke(SKColors.White, ring))
            canvas.DrawCircle(c, r - ring / 2, s);

        var label = a.Number.ToString();
        using var font = TextMetrics.BoldFont(label.Length > 1 ? r * 0.95 : r * 1.15);
        using var tp = Fill(a.Style.Color.PrefersDarkText ? SKColors.Black : SKColors.White);
        var width = font.MeasureText(label, out var bounds);
        canvas.DrawText(label, c.X - width / 2, c.Y - bounds.MidY, SKTextAlign.Left, font, tp);
    }

    private void DrawText(SKCanvas canvas, Annotation a, bool hideText)
    {
        var p = (float)TextMetrics.Padding(a);
        // Always measure: files from other clients (or older versions) may store a stale box.
        var laidOut = a.Clone();
        TextMetrics.Layout(laidOut);
        var r = laidOut.Rect.ToSK();
        if (a.Style.Filled)
        {
            var radius = (float)Math.Min(a.Style.FontSize * 0.35, Math.Min(r.Height / 2, r.Width / 2));
            using var _ = ShadowLayer(canvas, a);
            using var f = Fill(a.Style.Color.ToSK());
            canvas.DrawRoundRect(r, radius, radius, f);
        }
        if (hideText) return;
        using var font = TextMetrics.Font(a);
        using var tp = Fill(TextMetrics.TextColor(a));
        var y = r.Top + p - font.Metrics.Ascent;
        if (!a.Style.Filled)
        {
            using var _ = ShadowLayer(canvas, a);
            foreach (var line in TextMetrics.Lines(a.Text)) { canvas.DrawText(line, r.Left + p, y, SKTextAlign.Left, font, tp); y += font.Spacing; }
            return;
        }
        foreach (var line in TextMetrics.Lines(a.Text)) { canvas.DrawText(line, r.Left + p, y, SKTextAlign.Left, font, tp); y += font.Spacing; }
    }

    private void DrawSpotlights(SKCanvas canvas, List<Annotation> spots, SKRect full)
    {
        canvas.SaveLayer();
        var dim = spots.Max(s => s.Style.Opacity);
        using (var f = new SKPaint { Color = new SKColor(0, 0, 0, (byte)Math.Round(Math.Clamp(dim, 0, 1) * 255)) })
            canvas.DrawRect(full, f);
        using var clear = new SKPaint { IsAntialias = true, BlendMode = SKBlendMode.Clear };
        foreach (var s in spots)
        {
            var r = s.Rect.ToSK();
            var radius = (float)Math.Min(12 * Unit, Math.Min(r.Width / 2, r.Height / 2));
            canvas.DrawRoundRect(r, radius, radius, clear);
        }
        canvas.Restore();
    }

    private void ResetCacheIfNeeded(SKImage baseImage)
    {
        if (ReferenceEquals(cacheSource, baseImage)) return;
        foreach (var img in effectCache.Values) img.Dispose();
        effectCache.Clear();
        cacheSource = baseImage;
    }

    /// <summary>A heavy Gaussian blur (block size × 1.6, at least 12 px) so text underneath can't be read back.</summary>
    private SKImage? Blurred(SKImage baseImage, double block)
    {
        ResetCacheIfNeeded(baseImage);
        var radius = Math.Max(12, block * 1.6);
        var key = -(int)Math.Round(radius);
        if (effectCache.TryGetValue(key, out var cached)) return cached;
        using var surface = SKSurface.Create(new SKImageInfo(baseImage.Width, baseImage.Height, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
        if (surface == null) return null;
        using var paint = new SKPaint { ImageFilter = SKImageFilter.CreateBlur((float)radius, (float)radius, SKShaderTileMode.Clamp) };
        surface.Canvas.DrawImage(baseImage, 0, 0, paint);
        return effectCache[key] = surface.Snapshot();
    }

    /// <summary>Blocks of block × block pixels, aligned to the image's top-left, each the average of what it covers.</summary>
    private SKImage? Pixelated(SKImage baseImage, double block)
    {
        ResetCacheIfNeeded(baseImage);
        var key = Math.Max(2, (int)Math.Round(block));
        if (effectCache.TryGetValue(key, out var cached)) return cached;
        int sw = Math.Max(1, (int)Math.Ceiling(baseImage.Width / (double)key)), sh = Math.Max(1, (int)Math.Ceiling(baseImage.Height / (double)key));
        using var small = SKSurface.Create(new SKImageInfo(sw, sh, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
        using var big = SKSurface.Create(new SKImageInfo(baseImage.Width, baseImage.Height, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
        if (small == null || big == null) return null;
        small.Canvas.DrawImage(baseImage, new SKRect(0, 0, baseImage.Width / (float)key, baseImage.Height / (float)key),
                               new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        using var smallImage = small.Snapshot();
        big.Canvas.DrawImage(smallImage, new SKRect(0, 0, sw * key, sh * key), new SKSamplingOptions(SKFilterMode.Nearest, SKMipmapMode.None));
        return effectCache[key] = big.Snapshot();
    }

    /// <summary>Decoded pictures for image layers, by annotation id (PNG data compared to catch replacements).</summary>
    private SKImage? LayerImage(Annotation a)
    {
        if (a.ImagePng is not { } data) return null;
        if (layerCache.TryGetValue(a.Id, out var hit) && ReferenceEquals(hit.Data, data)) return hit.Image;
        var image = SKImage.FromEncodedData(data);
        if (image == null) return null;
        if (layerCache.Count > 64) { foreach (var v in layerCache.Values) v.Image.Dispose(); layerCache.Clear(); }
        layerCache[a.Id] = (data, image);
        return image;
    }
}
