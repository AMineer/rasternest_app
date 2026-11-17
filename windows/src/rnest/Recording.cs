using System.Diagnostics;
using System.Threading.Channels;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;
using SkiaSharp;

namespace RasterNest.Cli;

public sealed class RecordRequest
{
    public CaptureSpec Capture { get; set; } = new();
    public uint? WindowId { get; set; }
    /// <summary>Seconds to record. Null: until During finishes, or until stopped.</summary>
    public double? Duration { get; set; }
    /// <summary>Command started once recording is running (drive the UI, open a URL…).</summary>
    public string? During { get; set; }
    public string WorkingDirectory { get; set; } = Environment.CurrentDirectory;
    public int Fps { get; set; } = 30;
    public bool Cursor { get; set; } = true;
    /// <summary>Where to keep the MP4 (null = don't keep it).</summary>
    public string? Mp4 { get; set; }
    /// <summary>Where to write a GIF (null = no GIF).</summary>
    public string? Gif { get; set; }
    public int GifWidth { get; set; } = 800;
    public double GifFps { get; set; } = 12;
    /// <summary>Cap for recordings with no duration, so nothing records forever by accident.</summary>
    public double MaxDuration { get; set; } = 600;
}

public sealed record RecordResult(string? Mp4, string? Gif, double Seconds, int Width, int Height);

public static class Recording
{
    public static async Task<RecordResult> Record(RecordRequest req, CancellationToken stop, Action<string> log)
    {
        if (req.Mp4 == null && req.Gif == null) throw new UsageException("Choose an MP4 or GIF output.");
        RecordTarget target;
        if (req.WindowId is { } id) target = new RecordTarget.Window(id);
        else if (req.Capture.Window != null || req.Capture.App != null)
            target = new RecordTarget.Window(ScreenCapture.FindWindow(req.Capture.App, req.Capture.Title, req.Capture.Window).Id);
        else if (req.Capture.Rect is { } r)
        {
            if (r.Count != 4 || r[2] <= 0 || r[3] <= 0) throw new UsageException("`rect` must be [x, y, width, height].");
            target = new RecordTarget.Area(new RectD(r[0], r[1], r[2], r[3]));
        }
        else target = new RecordTarget.Display(req.Capture.Display);

        await using var recorder = new ScreenRecorder(target, new RecorderOptions(req.Fps, req.Cursor));
        var tmp = Path.Combine(Path.GetTempPath(), $"rnest-{Guid.NewGuid():N}.mp4");
        LiveGif? gif = null;
        try
        {
            await recorder.StartAsync(tmp);
            if (req.Gif != null)
            {
                gif = new LiveGif(req.Gif, recorder.PixelSize, req.GifWidth, req.GifFps);
                recorder.FrameSink = gif.Offer;
            }
            var startedAt = Stopwatch.StartNew();
            using var done = CancellationTokenSource.CreateLinkedTokenSource(stop);

            Process? during = null;
            if (req.During is { } command)
            {
                var psi = new ProcessStartInfo("cmd.exe", ["/d", "/s", "/c", command])
                {
                    WorkingDirectory = req.WorkingDirectory, UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true,
                };
                during = Process.Start(psi) ?? throw new UsageException($"Couldn't run `{command}`.");
                during.OutputDataReceived += (_, e) => { if (e.Data != null) Console.Error.WriteLine(e.Data); };
                during.BeginOutputReadLine();
                if (req.Duration == null)
                    _ = during.WaitForExitAsync().ContinueWith(async _ =>
                    {
                        // A short tail so the last change makes it into the video.
                        await Task.Delay(600);
                        done.Cancel();
                    });
            }

            var limit = TimeSpan.FromSeconds(req.Duration ?? req.MaxDuration);
            try { await Task.Delay(limit, done.Token); } catch (OperationCanceledException) { }
            if (during is { HasExited: false }) { try { during.Kill(entireProcessTree: true); } catch { } }

            var elapsed = await recorder.StopAsync();
            var (w, h) = recorder.PixelSize;
            log($"Recorded {elapsed.TotalSeconds:0.0} s at {w}×{h}.");

            string? gifPath = null;
            if (gif != null)
            {
                log("Finishing GIF…");
                await gif.FinishAsync();
                gifPath = req.Gif;
            }
            string? mp4Path = null;
            if (req.Mp4 != null)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(req.Mp4))!);
                File.Move(tmp, req.Mp4, overwrite: true);
                mp4Path = req.Mp4;
            }
            return new RecordResult(mp4Path, gifPath, elapsed.TotalSeconds, w, h);
        }
        finally
        {
            if (gif != null) await gif.DisposeAsync();
            try { File.Delete(tmp); } catch { }
        }
    }

    /// <summary>Writes a GIF while recording: frames are sampled at the GIF frame rate, scaled down, and encoded off-thread.</summary>
    private sealed class LiveGif : IAsyncDisposable
    {
        private readonly Channel<byte[]> frames = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
        private readonly Task worker;
        private readonly (int W, int H) source;
        private readonly double interval;
        private double next;

        public LiveGif(string path, (int W, int H) size, int maxWidth, double fps)
        {
            source = size;
            var f = Math.Clamp(fps, 1, 50);
            interval = 1 / f;
            var delayCs = (int)Math.Round(100 / f);
            var outW = maxWidth <= 0 || maxWidth >= size.W ? size.W : maxWidth;
            var outH = Math.Max(1, (int)Math.Round(size.H * (double)outW / size.W));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            worker = Task.Run(async () =>
            {
                await using var file = File.Create(path);
                using var encoder = new GifEncoder(file, outW, outH);
                var info = new SKImageInfo(source.W, source.H, SKColorType.Bgra8888, SKAlphaType.Premul);
                await foreach (var bytes in frames.Reader.ReadAllAsync())
                {
                    using var bmp = new SKBitmap(info);
                    System.Runtime.InteropServices.Marshal.Copy(bytes, 0, bmp.GetPixels(), bytes.Length);
                    bmp.NotifyPixelsChanged();
                    using var scaled = outW == source.W ? bmp.Copy() : bmp.Resize(new SKImageInfo(outW, outH, SKColorType.Bgra8888, SKAlphaType.Premul),
                                                                                  new SKSamplingOptions(SKCubicResampler.Mitchell));
                    encoder.AddFrame(scaled, delayCs);
                }
                encoder.Finish();
            });
        }

        public void Offer(byte[] frame, TimeSpan at)
        {
            if (at.TotalSeconds + 1e-6 < next) return;
            next += interval;
            frames.Writer.TryWrite(frame);
        }

        public Task FinishAsync()
        {
            frames.Writer.TryComplete();
            return worker;
        }

        public async ValueTask DisposeAsync()
        {
            frames.Writer.TryComplete();
            try { await worker; } catch { }
        }
    }

    /// <summary>Converts a video to a looping GIF.</summary>
    public static Task ConvertToGif(string video, string gif, double fps, int maxWidth) => GifExport.Convert(video, gif, fps, maxWidth);

    /// <summary>A frame from the middle of a recording (or the first GIF frame), as a small JPEG preview.</summary>
    public static async Task<byte[]?> Preview(string? mp4, string? gif)
    {
        try
        {
            if (mp4 != null)
            {
                var frames = await VideoFrames.OpenAsync(mp4);
                var (w, h) = frames.Size;
                var k = Math.Min(1, 1200.0 / Math.Max(w, h));
                using var frame = await frames.FrameAsync(frames.Duration / 2, (int)(w * k), (int)(h * k));
                using var image = SKImage.FromBitmap(frame);
                return AgentOps.Preview(image, 1200);
            }
            if (gif != null && SKBitmap.Decode(gif) is { } first)
            {
                using (first)
                using (var image = SKImage.FromBitmap(first)) return AgentOps.Preview(image, 1200);
            }
        }
        catch { /* a preview is optional */ }
        return null;
    }
}
