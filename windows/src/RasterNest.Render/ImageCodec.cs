using System.Buffers.Binary;
using RasterNest.Core;
using SkiaSharp;

namespace RasterNest.Render;

public enum ExportFormat { Png, Jpg }

public static class ExportFormats
{
    public static ExportFormat? FromExtension(string ext) => ext.TrimStart('.').ToLowerInvariant() switch
    {
        "png" => ExportFormat.Png,
        "jpg" or "jpeg" => ExportFormat.Jpg,
        _ => null,
    };
}

/// <summary>Reading and writing images and .rasternest documents.</summary>
public static class ImageCodec
{
    /// <summary>
    /// Encodes as PNG (with a pHYs chunk recording the pixel scale, as the Mac does: 2x → 144 dpi)
    /// or as JPEG flattened on white.
    /// </summary>
    public static byte[] Encode(SKImage image, ExportFormat format, double scale, int quality = 90)
    {
        if (format == ExportFormat.Jpg)
        {
            using var flat = FlattenOnWhite(image);
            using var jpg = flat.Encode(SKEncodedImageFormat.Jpeg, Math.Clamp(quality, 0, 100));
            return jpg.ToArray();
        }
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return WithDensity(data.ToArray(), scale);
    }

    public static byte[] EncodePng(SKBitmap bitmap, double scale)
    {
        using var image = SKImage.FromBitmap(bitmap);
        return Encode(image, ExportFormat.Png, scale);
    }

    /// <summary>Decodes image data; the scale comes from the PNG's density (144 dpi → 2x), else 1.</summary>
    public static (SKBitmap Bitmap, double Scale)? Decode(ReadOnlySpan<byte> data)
    {
        var bitmap = SKBitmap.Decode(data);
        if (bitmap == null) return null;
        // Normalize to premultiplied BGRA/RGBA 8888 so drawing and pixel access are predictable.
        if (bitmap.ColorType != SKImageInfo.PlatformColorType || bitmap.AlphaType != SKAlphaType.Premul)
        {
            var converted = new SKBitmap(new SKImageInfo(bitmap.Width, bitmap.Height, SKImageInfo.PlatformColorType, SKAlphaType.Premul));
            using (var canvas = new SKCanvas(converted)) canvas.DrawBitmap(bitmap, 0, 0);
            bitmap.Dispose();
            bitmap = converted;
        }
        var scale = PngInfo.Read(data)?.Scale ?? 1;
        return (bitmap, scale);
    }

    public static (SKBitmap Bitmap, double Scale)? Load(string path) => Decode(File.ReadAllBytes(path));

    public static (NestDocument Doc, SKBitmap Bitmap) LoadDocument(string path)
    {
        var doc = NestDocument.Load(path);
        var decoded = Decode(doc.ImagePng) ?? throw new InvalidDataException($"The picture inside {path} is damaged.");
        return (doc, decoded.Bitmap);
    }

    public static NestDocument MakeDocument(SKBitmap bitmap, double scale, IEnumerable<Annotation> annotations, CanvasEffects? effects = null) =>
        new(EncodePng(bitmap, scale), scale, annotations, effects);

    public static SKImage FlattenOnWhite(SKImage image)
    {
        using var surface = SKSurface.Create(new SKImageInfo(image.Width, image.Height, SKColorType.Rgba8888, SKAlphaType.Opaque));
        surface.Canvas.Clear(SKColors.White);
        surface.Canvas.DrawImage(image, 0, 0);
        return surface.Snapshot();
    }

    /// <summary>Inserts (or replaces) a pHYs chunk so other apps and RasterNest know the pixel scale.</summary>
    public static byte[] WithDensity(byte[] png, double scale)
    {
        if (png.Length < 33) return png;
        var ppm = (uint)Math.Round(72 * Math.Max(scale, 1) / 0.0254);
        var chunk = new byte[21];
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(0), 9);
        "pHYs"u8.CopyTo(chunk.AsSpan(4));
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(8), ppm);
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(12), ppm);
        chunk[16] = 1; // unit: metre
        BinaryPrimitives.WriteUInt32BigEndian(chunk.AsSpan(17), Crc32(chunk.AsSpan(4, 13)));

        using var output = new MemoryStream(png.Length + 21);
        output.Write(png, 0, 33); // signature + IHDR
        var i = 33;
        var inserted = false;
        while (i + 12 <= png.Length)
        {
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(i));
            var type = System.Text.Encoding.ASCII.GetString(png, i + 4, 4);
            var total = 12 + length;
            if (type == "pHYs") { i += total; continue; } // drop the old one
            if (!inserted && type == "IDAT") { output.Write(chunk); inserted = true; }
            output.Write(png, i, Math.Min(total, png.Length - i));
            i += total;
        }
        return output.ToArray();
    }

    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    private static uint Crc32(ReadOnlySpan<byte> data)
    {
        var c = 0xFFFFFFFFu;
        foreach (var b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
