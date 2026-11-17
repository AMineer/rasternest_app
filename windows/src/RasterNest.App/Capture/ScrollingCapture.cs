using RasterNest.Core;
using RasterNest.Windows;
using SkiaSharp;

namespace RasterNest.App.Capture;

/// <summary>
/// Scrolling capture: samples an area of the screen a few times a second while you scroll, and stitches the new
/// rows into one tall image (ScrollStitcher). Sticky headers and footers appear once. A port of the Mac session.
/// </summary>
internal sealed class ScrollingCapture
{
    private const int MaxHeight = 30_000;
    private readonly RectD area;
    private readonly double scale;
    private readonly ScrollStitcher stitcher = new();
    private readonly List<SKBitmap> strips = [];
    private SKBitmap? first, last;
    private CancellationTokenSource? loop;
    private CaptureBar? bar;
    private TaskCompletionSource<SKBitmap?>? result;

    public ScrollingCapture(RectD area, double scale)
    {
        this.area = area;
        this.scale = scale;
    }

    public double Scale => scale;

    /// <summary>Runs until Done (returns the stitched image) or Cancel (returns null).</summary>
    public Task<SKBitmap?> RunAsync()
    {
        result = new TaskCompletionSource<SKBitmap?>();
        bar = new CaptureBar("Scroll down slowly", "Done", Finish, Cancel, pulse: false);
        bar.Show();
        loop = new CancellationTokenSource();
        _ = Sample(loop.Token);
        return result.Task;
    }

    private async Task Sample(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var shot = ScreenCapture.CaptureRect(area);
                var bmp = shot.Bitmap;
                var sig = RowSignature.FromPixels(bmp.GetPixelSpan(), bmp.Width, bmp.Height, bmp.RowBytes);
                switch (stitcher.Add(sig))
                {
                    case StitchStep.First:
                        first = bmp;
                        last = bmp;
                        break;
                    case StitchStep.Append(var from, var count):
                        var strip = new SKBitmap(bmp.Width, count, bmp.ColorType, bmp.AlphaType);
                        using (var c = new SKCanvas(strip))
                            c.DrawBitmap(bmp, SKRect.Create(0, from, bmp.Width, count), SKRect.Create(0, 0, bmp.Width, count));
                        strips.Add(strip);
                        if (!ReferenceEquals(last, first)) last?.Dispose();
                        last = bmp;
                        break;
                    default:
                        bmp.Dispose();
                        break;
                }
                bar?.SetStatus(stitcher.MismatchStreak >= 4
                    ? "Scroll a little slower"
                    : $"Scroll down slowly · {stitcher.TotalHeight:N0} px");
                if (stitcher.TotalHeight >= MaxHeight) { Finish(); return; }
            }
            catch (Exception e)
            {
                Log.Write($"scrolling sample failed: {e.Message}");
            }
            try { await Task.Delay(110, ct); } catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Done: stitch what's been captured so far.</summary>
    public void Finish()
    {
        loop?.Cancel();
        bar?.Close();
        result?.TrySetResult(Assemble());
        Cleanup();
    }

    private void Cancel()
    {
        loop?.Cancel();
        bar?.Close();
        result?.TrySetResult(null);
        Cleanup();
    }

    /// <summary>First frame (minus the sticky footer), every new strip, then the footer from the last frame.</summary>
    private SKBitmap? Assemble()
    {
        if (first == null) return null;
        var w = first.Width;
        var rows = first.Height;
        var footer = stitcher.Footer;
        var output = new SKBitmap(w, stitcher.TotalHeight, first.ColorType, first.AlphaType);
        using var c = new SKCanvas(output);
        c.DrawBitmap(first, SKRect.Create(0, 0, w, rows - footer), SKRect.Create(0, 0, w, rows - footer));
        var y = rows - footer;
        foreach (var s in strips)
        {
            c.DrawBitmap(s, 0, y);
            y += s.Height;
        }
        if (footer > 0 && last != null)
            c.DrawBitmap(last, SKRect.Create(0, rows - footer, w, footer), SKRect.Create(0, y, w, footer));
        return output;
    }

    private void Cleanup()
    {
        foreach (var s in strips) s.Dispose();
        strips.Clear();
        if (!ReferenceEquals(last, first)) last?.Dispose();
        first?.Dispose();
        first = last = null;
    }
}
