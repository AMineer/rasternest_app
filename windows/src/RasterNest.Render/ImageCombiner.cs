using RasterNest.Core;
using SkiaSharp;

namespace RasterNest.Render;

/// <summary>Draws several images into one using a <see cref="CombineLayout"/>.</summary>
public static class ImageCombiner
{
    /// <summary>Longest side of the result; bigger layouts are scaled down to fit.</summary>
    public const double MaxSide = 16_384;

    private static (CombineLayout.Result Placed, double Scale) Place(IReadOnlyList<(SKImage Image, double Scale)> images, CombineLayout layout)
    {
        var scale = images.Max(i => i.Scale);
        // Bring every image to the same density so a 1x and a 2x capture line up.
        var sizes = images.Select(i => new SizeD(i.Image.Width * scale / Math.Max(i.Scale, 1), i.Image.Height * scale / Math.Max(i.Scale, 1))).ToList();
        var placed = layout.Place(sizes);
        var longest = Math.Max(placed.Canvas.Width, placed.Canvas.Height);
        if (longest > MaxSide)
        {
            var f = MaxSide / longest;
            placed = new CombineLayout.Result(
                new SizeD(Math.Round(placed.Canvas.Width * f), Math.Round(placed.Canvas.Height * f)),
                placed.Frames.Select(r => new RectD(r.MinX * f, r.MinY * f, r.Width * f, r.Height * f).Integral).ToList());
        }
        return (placed, scale);
    }

    /// <summary>One flat image. background null = transparent. Returns the image and its pixels-per-point scale.</summary>
    public static (SKImage Image, double Scale)? Combine(IReadOnlyList<(SKImage Image, double Scale)> images, CombineLayout layout,
                                                         Rgba? background, bool numbered = false)
    {
        if (images.Count == 0) return null;
        if (numbered)
        {
            if (Layered(images, layout, background, numbered: true) is not { } r) return null;
            using var canvasImage = SKImage.FromBitmap(r.Canvas);
            var flat = new AnnotationRenderer(r.Scale).Flatten(canvasImage, r.Layers);
            r.Canvas.Dispose();
            return (flat, r.Scale);
        }
        var (placed, scale) = Place(images, layout);
        int w = (int)placed.Canvas.Width, h = (int)placed.Canvas.Height;
        if (w <= 0 || h <= 0) return null;
        using var surface = SKSurface.Create(new SKImageInfo(w, h, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
        surface.Canvas.Clear(background?.ToSK() ?? SKColors.Transparent);
        var sampling = new SKSamplingOptions(SKCubicResampler.Mitchell);
        foreach (var ((image, _), frame) in images.Zip(placed.Frames))
            surface.Canvas.DrawImage(image, frame.ToSK(), sampling);
        return (surface.Snapshot(), scale);
    }

    /// <summary>
    /// The same layout as Combine, but as a blank canvas with each picture as a separate image layer,
    /// so pieces can still be moved, resized or overlapped afterwards.
    /// </summary>
    public static (SKBitmap Canvas, List<Annotation> Layers, double Scale)? Layered(IReadOnlyList<(SKImage Image, double Scale)> images,
        CombineLayout layout, Rgba? background, bool numbered = false)
    {
        if (images.Count == 0) return null;
        var (placed, scale) = Place(images, layout);
        int w = Math.Max(1, (int)placed.Canvas.Width), h = Math.Max(1, (int)placed.Canvas.Height);
        var canvas = new SKBitmap(new SKImageInfo(w, h, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
        canvas.Erase(background?.ToSK() ?? SKColors.Transparent);
        var layers = new List<Annotation>();
        for (var i = 0; i < images.Count; i++)
        {
            var (image, s) = images[i];
            var frame = placed.Frames[i];
            using var data = image.Encode(SKEncodedImageFormat.Png, 100);
            var png = ImageCodec.WithDensity(data.ToArray(), s);
            layers.Add(new Annotation(AnnotationKind.Image, frame.Origin, new PointD(frame.MaxX, frame.MaxY), number: numbered ? i + 1 : 0,
                style: new AnnotationStyle { Color = Rgba.White, LineWidth = 0, Shadow = false, Opacity = 1 }, imagePng: png));
        }
        return (canvas, layers, scale);
    }
}

/// <summary>Writes one or more captures into a PDF, one per page.</summary>
public static class PdfComposer
{
    public enum PageSize { Fit, Letter, A4 }

    public sealed record Page(SKImage Image, double Scale, string? Caption = null);

    public static void Write(IReadOnlyList<Page> pages, string path, PageSize pageSize = PageSize.Fit, float margin = 36, string? title = null)
    {
        if (pages.Count == 0) throw new InvalidOperationException("There's nothing to put in the PDF.");
        using var stream = new SKFileWStream(path);
        var metadata = new SKDocumentPdfMetadata { Creator = "RasterNest", Producer = "RasterNest", RasterDpi = 144 };
        if (title != null) metadata.Title = title;
        using var doc = SKDocument.CreatePdf(stream, metadata) ?? throw new IOException("Couldn't create the PDF file.");
        using var captionFont = new SKFont(SKTypeface.FromFamilyName("Segoe UI", SKFontStyle.Normal), 11);
        using var captionPaint = new SKPaint { IsAntialias = true, Color = new SKColor(51, 65, 85) };
        var sampling = new SKSamplingOptions(SKCubicResampler.Mitchell);

        foreach (var page in pages)
        {
            float iw = (float)(page.Image.Width / page.Scale), ih = (float)(page.Image.Height / page.Scale);
            float captionHeight = page.Caption == null ? 0 : 24;
            SKSize media;
            SKRect imageRect;
            SKSize? fixedSize = pageSize switch { PageSize.Letter => new SKSize(612, 792), PageSize.A4 => new SKSize(595.28f, 841.89f), _ => null };
            if (fixedSize is { } f)
            {
                media = f;
                float aw = f.Width - margin * 2, ah = f.Height - margin * 2 - captionHeight;
                var k = Math.Min(1, Math.Min(aw / iw, ah / ih));
                float w = iw * k, h = ih * k;
                imageRect = SKRect.Create((f.Width - w) / 2, margin, w, h);
            }
            else
            {
                float pad = page.Caption == null ? 0 : 16;
                media = new SKSize(iw + pad * 2, ih + captionHeight + pad * 2);
                imageRect = SKRect.Create(pad, pad, iw, ih);
            }
            var canvas = doc.BeginPage(media.Width, media.Height);
            canvas.DrawImage(page.Image, imageRect, sampling);
            if (page.Caption is { } caption)
                canvas.DrawText(caption, imageRect.Left, imageRect.Bottom + 16, SKTextAlign.Left, captionFont, captionPaint);
            doc.EndPage();
        }
        doc.Close();
    }
}
