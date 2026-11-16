using System.Runtime.InteropServices.WindowsRuntime;
using RasterNest.Core;
using SkiaSharp;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using OcrResult = RasterNest.Core.OcrResult;
using Windows.Storage.Streams;

namespace RasterNest.Windows;

/// <summary>Text with positions, using the OCR built into Windows (Windows.Media.Ocr).</summary>
public static class TextRecognition
{
    /// <summary>Lines and words in image pixels, origin top-left.</summary>
    public static async Task<OcrResult> AnalyzeAsync(byte[] imageData)
    {
        using var bitmap = SKBitmap.Decode(imageData) ?? throw new CaptureException("Couldn't read the image for text recognition.");
        var scale = PngInfo.Read(imageData)?.Scale ?? 1;
        var lines = await AnalyzeAsync(bitmap);
        return new OcrResult(bitmap.Width, bitmap.Height, scale, lines);
    }

    public static async Task<List<TextLine>> AnalyzeAsync(SKBitmap source)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.TryCreateFromLanguage(new global::Windows.Globalization.Language("en-US"))
            ?? throw new CaptureException("Windows has no OCR language installed. Add one in Settings › Time & language › Language & region.");

        // Windows OCR reads small UI text better a little enlarged, and refuses images over MaxImageDimension.
        var longest = Math.Max(source.Width, source.Height);
        var factor = longest * 2 <= OcrEngine.MaxImageDimension && source.Height < 1200 ? 2.0 : 1.0;
        if (longest * factor > OcrEngine.MaxImageDimension) factor = (double)OcrEngine.MaxImageDimension / longest;

        using var software = await ToSoftwareBitmap(source, factor);
        var result = await engine.RecognizeAsync(software);

        var lines = new List<TextLine>();
        foreach (var line in result.Lines)
        {
            var words = line.Words.Select(w => new TextWord(w.Text, new PixelBox(
                w.BoundingRect.X / factor, w.BoundingRect.Y / factor, w.BoundingRect.Width / factor, w.BoundingRect.Height / factor))).ToList();
            if (words.Count == 0) continue;
            var box = PixelBox.Union(words.Select(w => w.Box))!.Value;
            lines.Add(new TextLine(line.Text, 1, box, words));
        }
        return TextMatcher.ReadingOrder(lines);
    }

    public static async Task<string> RecognizeAsync(byte[] imageData) => (await AnalyzeAsync(imageData)).Text;

    private static async Task<SoftwareBitmap> ToSoftwareBitmap(SKBitmap source, double factor)
    {
        SKBitmap bgra;
        if (Math.Abs(factor - 1) < 0.001 && source.ColorType == SKColorType.Bgra8888)
            bgra = source.Copy();
        else
        {
            var info = new SKImageInfo((int)Math.Round(source.Width * factor), (int)Math.Round(source.Height * factor), SKColorType.Bgra8888, SKAlphaType.Premul);
            bgra = source.Resize(info, new SKSamplingOptions(SKCubicResampler.Mitchell)) ?? source.Copy();
        }
        using (bgra)
        {
            // Encode through PNG into an in-memory stream: the simplest safe route into a SoftwareBitmap.
            using var data = SKImage.FromBitmap(bgra).Encode(SKEncodedImageFormat.Png, 100);
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(data.ToArray().AsBuffer());
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        }
    }
}
