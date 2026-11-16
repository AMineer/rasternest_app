using System.Runtime.InteropServices;
using RasterNest.Render;
using SkiaSharp;
using static RasterNest.Windows.Native;

namespace RasterNest.Windows;

/// <summary>Copies images (as PNG and a DIB, so every app can paste) and text.</summary>
public static class Clipboard
{
    public static void CopyText(string text)
    {
        var bytes = System.Text.Encoding.Unicode.GetBytes(text + "\0");
        WithClipboard(() => Put(CF_UNICODETEXT, bytes));
    }

    public static void CopyPng(byte[] png)
    {
        using var bitmap = SKBitmap.Decode(png) ?? throw new CaptureException("Couldn't read the image to copy.");
        var dib = DibV5(bitmap);
        var pngFormat = RegisterClipboardFormat("PNG");
        WithClipboard(() =>
        {
            Put(CF_DIBV5, dib);
            Put(pngFormat, png);
        });
    }

    public static void CopyImage(SKImage image, double scale) => CopyPng(ImageCodec.Encode(image, ExportFormat.Png, scale));

    private static void WithClipboard(Action body)
    {
        // Another app may hold the clipboard for a moment.
        for (var attempt = 0; ; attempt++)
        {
            if (OpenClipboard(IntPtr.Zero)) break;
            if (attempt >= 10) throw new CaptureException("The clipboard is busy. Try again.");
            Thread.Sleep(30);
        }
        try
        {
            EmptyClipboard();
            body();
        }
        finally { CloseClipboard(); }
    }

    private static void Put(uint format, byte[] bytes)
    {
        var mem = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (mem == IntPtr.Zero) throw new OutOfMemoryException();
        var ptr = GlobalLock(mem);
        Marshal.Copy(bytes, 0, ptr, bytes.Length);
        GlobalUnlock(mem);
        if (SetClipboardData(format, mem) == IntPtr.Zero) GlobalFree(mem);
    }

    /// <summary>A bottom-up 32-bit BITMAPV5HEADER image with alpha (straight, as most apps expect).</summary>
    private static byte[] DibV5(SKBitmap source)
    {
        using var bgra = new SKBitmap(new SKImageInfo(source.Width, source.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul));
        source.CopyTo(bgra, SKColorType.Bgra8888);
        int w = bgra.Width, h = bgra.Height, stride = w * 4;
        const int headerSize = 124;
        var output = new byte[headerSize + stride * h];
        var span = output.AsSpan();
        BitConverter.TryWriteBytes(span[0..], headerSize);
        BitConverter.TryWriteBytes(span[4..], w);
        BitConverter.TryWriteBytes(span[8..], h);              // positive: bottom-up
        BitConverter.TryWriteBytes(span[12..], (short)1);       // planes
        BitConverter.TryWriteBytes(span[14..], (short)32);      // bits
        BitConverter.TryWriteBytes(span[16..], 3);              // BI_BITFIELDS
        BitConverter.TryWriteBytes(span[20..], stride * h);
        BitConverter.TryWriteBytes(span[40..], 0x00FF0000u);    // red mask
        BitConverter.TryWriteBytes(span[44..], 0x0000FF00u);    // green
        BitConverter.TryWriteBytes(span[48..], 0x000000FFu);    // blue
        BitConverter.TryWriteBytes(span[52..], 0xFF000000u);    // alpha
        BitConverter.TryWriteBytes(span[56..], 0x73524742u);    // LCS_sRGB
        BitConverter.TryWriteBytes(span[108..], 4);             // LCS_GM_IMAGES
        var pixels = bgra.GetPixelSpan();
        for (var y = 0; y < h; y++)
            pixels.Slice(y * bgra.RowBytes, stride).CopyTo(span.Slice(headerSize + (h - 1 - y) * stride, stride));
        return output;
    }
}
