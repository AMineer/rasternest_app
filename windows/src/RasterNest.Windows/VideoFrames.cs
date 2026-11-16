using System.Runtime.InteropServices.WindowsRuntime;
using SkiaSharp;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;

namespace RasterNest.Windows;

/// <summary>Reads frames out of a video file (MP4/MOV) with Windows' media stack, for MP4 → GIF.</summary>
public sealed class VideoFrames
{
    private readonly MediaComposition composition = new();
    public TimeSpan Duration { get; private set; }
    public (int Width, int Height) Size { get; private set; }

    private VideoFrames() { }

    public static async Task<VideoFrames> OpenAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        MediaClip clip;
        try { clip = await MediaClip.CreateFromFileAsync(file); }
        catch (Exception e) { throw new CaptureException($"Couldn't read {Path.GetFileName(path)} as a video ({e.Message})."); }
        var v = new VideoFrames { Duration = clip.OriginalDuration };
        var props = clip.GetVideoEncodingProperties();
        v.Size = ((int)props.Width, (int)props.Height);
        v.composition.Clips.Add(clip);
        return v;
    }

    /// <summary>The frame at time, scaled to width × height.</summary>
    public async Task<SKBitmap> FrameAsync(TimeSpan time, int width, int height)
    {
        using var stream = await composition.GetThumbnailAsync(time, width, height, VideoFramePrecision.NearestFrame);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var sb = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var bitmap = new SKBitmap(new SKImageInfo(sb.PixelWidth, sb.PixelHeight, SKColorType.Bgra8888, SKAlphaType.Premul));
        var bytes = new byte[sb.PixelWidth * sb.PixelHeight * 4];
        sb.CopyToBuffer(bytes.AsBuffer());
        System.Runtime.InteropServices.Marshal.Copy(bytes, 0, bitmap.GetPixels(), bytes.Length);
        bitmap.NotifyPixelsChanged();
        return bitmap;
    }
}
