using RasterNest.Render;
using SkiaSharp;

namespace RasterNest.Windows;

/// <summary>Turns a video (or part of it) into a looping GIF. Shared by rnest and the app's video pane.</summary>
public static class GifExport
{
    public static async Task Convert(string video, string gif, double fps = 12, int maxWidth = 800,
                                     TimeSpan? start = null, TimeSpan? end = null, IProgress<double>? progress = null,
                                     CancellationToken cancel = default)
    {
        var frames = await VideoFrames.OpenAsync(video);
        var f = Math.Clamp(fps, 1, 50);
        var delayCs = (int)Math.Round(100 / f);
        var (vw, vh) = frames.Size;
        int w = maxWidth <= 0 || maxWidth >= vw ? vw : maxWidth;
        int h = Math.Max(1, (int)Math.Round(vh * (double)w / vw));
        var from = start ?? TimeSpan.Zero;
        var to = end is { } e && e > from && e <= frames.Duration ? e : frames.Duration;
        var count = Math.Max(1, (int)Math.Floor((to - from).TotalSeconds / (delayCs / 100.0)));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(gif))!);
        var tmp = gif + ".partial";
        await using (var file = File.Create(tmp))
        using (var encoder = new GifEncoder(file, w, h))
        {
            for (var i = 0; i < count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                using var frame = await frames.FrameAsync(from + TimeSpan.FromSeconds(i * delayCs / 100.0), w, h);
                using var sized = frame.Width == w && frame.Height == h ? frame.Copy()
                    : frame.Resize(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul), new SKSamplingOptions(SKCubicResampler.Mitchell));
                encoder.AddFrame(sized, delayCs);
                progress?.Report((i + 1) / (double)count);
            }
        }
        File.Move(tmp, gif, overwrite: true);
    }
}
