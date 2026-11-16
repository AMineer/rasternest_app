using RasterNest.Core;
using RasterNest.Render;
using SkiaSharp;

namespace RasterNest.Render.Tests;

public class RenderTests
{
    private static SKImage Solid(int w, int h, SKColor c)
    {
        using var s = SKSurface.Create(new SKImageInfo(w, h));
        s.Canvas.Clear(c);
        return s.Snapshot();
    }

    private static SKColor PixelAt(SKImage image, int x, int y)
    {
        using var bmp = SKBitmap.FromImage(image);
        return bmp.GetPixel(x, y);
    }

    [Fact]
    public void FlattenAddsFramePadding()
    {
        using var img = Solid(100, 50, SKColors.White);
        using var flat = new AnnotationRenderer(1).Flatten(img, [], CanvasEffects.Documentation(1));
        Assert.Equal(164, flat.Width);
        Assert.Equal(114, flat.Height);
    }

    [Fact]
    public void RectangleStrokeIsDrawn()
    {
        using var img = Solid(100, 100, SKColors.White);
        var a = new Annotation(AnnotationKind.Rectangle, new PointD(10, 10), new PointD(90, 90),
                               style: new AnnotationStyle { Color = Rgba.Red, LineWidth = 4, Shadow = false });
        using var flat = new AnnotationRenderer().Flatten(img, [a]);
        var edge = PixelAt(flat, 10, 50);
        Assert.True(edge.Red > 200 && edge.Green < 100, $"edge was {edge}");
        Assert.Equal(SKColors.White, PixelAt(flat, 50, 50));
    }

    [Fact]
    public void PixelateHidesDetail()
    {
        using var s = SKSurface.Create(new SKImageInfo(40, 40));
        s.Canvas.Clear(SKColors.White);
        using (var p = new SKPaint { Color = SKColors.Black }) s.Canvas.DrawRect(0, 0, 20, 40, p);
        using var img = s.Snapshot();
        var a = new Annotation(AnnotationKind.Pixelate, new PointD(0, 0), new PointD(40, 40), style: new AnnotationStyle { LineWidth = 40, Shadow = false });
        using var flat = new AnnotationRenderer().Flatten(img, [a]);
        var c = PixelAt(flat, 5, 5);
        Assert.InRange(c.Red, 90, 165); // one 40px block: an average grey
        Assert.Equal(c, PixelAt(flat, 35, 35));
    }

    [Fact]
    public void PngKeepsItsScale()
    {
        using var img = Solid(4, 4, SKColors.Blue);
        var png = ImageCodec.Encode(img, ExportFormat.Png, 2);
        Assert.Equal(new PngInfo(4, 4, 2), PngInfo.Read(png));
        var decoded = ImageCodec.Decode(png)!.Value;
        Assert.Equal(2, decoded.Scale);
        Assert.Equal(1.5, PngInfo.Read(ImageCodec.Encode(img, ExportFormat.Png, 1.5))!.Value.Scale);
    }

    [Fact]
    public void RendersTheMacSampleWithEveryKind()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "mac-sample.rasternest");
        var (doc, bmp) = ImageCodec.LoadDocument(path);
        using var flat = new AnnotationRenderer(doc.PixelScale).Flatten(bmp, doc.Annotations, doc.Effects);
        Assert.Equal(600 + 128, flat.Width);
        var outDir = Environment.GetEnvironmentVariable("RN_RENDER_OUT");
        if (outDir != null) File.WriteAllBytes(Path.Combine(outDir, "mac-sample-windows.png"), ImageCodec.Encode(flat, ExportFormat.Png, doc.PixelScale));
    }

    [Fact]
    public void CombineSideBySide()
    {
        using var a = Solid(100, 50, SKColors.Red);
        using var b = Solid(50, 50, SKColors.Blue);
        var r = ImageCombiner.Combine([(a, 1), (b, 1)], new CombineLayout { Gap = 10 }, Rgba.White)!.Value;
        Assert.Equal(160, r.Image.Width);
        Assert.Equal(50, r.Image.Height);
        var layered = ImageCombiner.Layered([(a, 1), (b, 1)], new CombineLayout { Gap = 10 }, null, numbered: true)!.Value;
        Assert.Equal(2, layered.Layers.Count);
        Assert.Equal(2, layered.Layers[1].Number);
    }

    [Fact]
    public void PdfHasPages()
    {
        using var a = Solid(100, 50, SKColors.Red);
        var path = Path.Combine(Path.GetTempPath(), $"rn-{Guid.NewGuid()}.pdf");
        PdfComposer.Write([new(a, 1, "One"), new(a, 2)], path, PdfComposer.PageSize.Letter);
        var head = File.ReadAllText(path);
        File.Delete(path);
        Assert.StartsWith("%PDF", head);
        Assert.Contains("/Count 2", head);
    }
}
