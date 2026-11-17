using RasterNest.Core;
using RasterNest.Render;
using SkiaSharp;

namespace RasterNest.App.Library;

/// <summary>
/// The captures folder, as the list shown in the editor's strip and the tray's Recent menu.
/// Each capture is Name.rasternest (editable) plus, when "Keep a PNG" is on, Name.png (the rendered result,
/// refreshed on every save), so the folder always holds ready-to-use images. Same layout as the Mac app.
/// </summary>
public sealed class CaptureLibrary
{
    public static CaptureLibrary Shared { get; } = new();

    public sealed record Item(string Id, string Name, string DocumentPath, string? ImagePath, string? VideoPath, DateTime Date, bool IsExternal = false)
    {
        public bool IsVideo => VideoPath != null;
        public bool HasDocument => File.Exists(DocumentPath);
        /// <summary>Best file to hand to other apps (drag, Explorer).</summary>
        public string SharePath => VideoPath ?? ImagePath ?? DocumentPath;
    }

    public static readonly HashSet<string> ImageExtensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp"];
    public static readonly HashSet<string> VideoExtensions = [".mp4", ".mov", ".wmv"];
    public const int Limit = 300;

    private readonly List<Item> externals = [];
    private readonly Dictionary<string, byte[]> thumbnails = [];

    public List<Item> Items { get; private set; } = [];
    public event Action? Changed;

    public string Folder => AppSettings.Shared.SaveFolder;

    /// <summary>
    /// Where captures go when Windows refuses writes to <see cref="Folder"/> (Controlled folder access, permissions),
    /// so a capture is never lost. Listed in the strip alongside the normal folder.
    /// </summary>
    public static string FallbackFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RasterNest", "Captures");

    /// <summary>The captures folder Windows last refused to write to (null when saving works).</summary>
    public string? BlockedFolder { get; private set; }

    /// <summary>Raised the first time a save is refused, with the folder that was blocked.</summary>
    public event Action<string>? SaveBlocked;

    /// <summary>True for "access denied" failures (Controlled folder access reports itself this way).</summary>
    public static bool IsAccessDenied(Exception e) =>
        e is UnauthorizedAccessException || (e is IOException io && (io.HResult & 0xFFFF) == 5);

    /// <summary>A message for a failed save that says what to do about it.</summary>
    public static string Explain(Exception e, string folder) => IsAccessDenied(e)
        ? $"Windows blocked RasterNest from saving to {folder}. If Controlled folder access is on, allow RasterNest in " +
          "Windows Security › Virus & threat protection › Manage ransomware protection, or choose another captures folder in Settings."
        : e.Message;

    /// <summary>Runs a save into the captures folder; if Windows refuses, runs it again into the fallback folder.</summary>
    private T WithFallback<T>(Func<string, T> save)
    {
        try
        {
            Directory.CreateDirectory(Folder);
            var result = save(Folder);
            RasterNest.App.Log.Write($"saved in {Folder}");
            BlockedFolder = null;
            return result;
        }
        catch (Exception e) when (IsAccessDenied(e) && !string.Equals(Folder, FallbackFolder, StringComparison.OrdinalIgnoreCase))
        {
            var first = BlockedFolder == null;
            BlockedFolder = Folder;
            RasterNest.App.Log.Write($"save blocked in {Folder}: {e.Message}; using {FallbackFolder}");
            Directory.CreateDirectory(FallbackFolder);
            var result = save(FallbackFolder);
            if (first) SaveBlocked?.Invoke(Folder);
            return result;
        }
    }

    public void Reload()
    {
        var byBase = new Dictionary<string, Item>(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in new[] { Folder, FallbackFolder }.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(folder)) continue;
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(folder).ToList(); } catch { continue; }
            foreach (var path in files)
            {
                var ext = Path.GetExtension(path).ToLowerInvariant();
                var isDoc = ext == "." + NestDocument.FileExtension;
                var isVideo = VideoExtensions.Contains(ext);
                if (!isDoc && !isVideo && !ImageExtensions.Contains(ext)) continue;
                if (File.GetAttributes(path).HasFlag(FileAttributes.Hidden)) continue;
                var basePath = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path));
                var date = File.GetCreationTime(path);
                var item = byBase.GetValueOrDefault(basePath)
                           ?? new Item(basePath, Path.GetFileName(basePath), basePath + "." + NestDocument.FileExtension, null, null, date);
                if (isVideo) item = item with { VideoPath = path };
                else if (!isDoc && (item.ImagePath == null || ext == ".png")) item = item with { ImagePath = path };
                item = item with { Date = date < item.Date ? date : item.Date };
                byBase[basePath] = item;
            }
        }
        var sorted = byBase.Values.OrderByDescending(i => i.Date).ThenByDescending(i => i.Name).Take(Limit);
        Items = [.. externals, .. sorted];
        Changed?.Invoke();
    }

    public Item? Find(string id) => Items.FirstOrDefault(i => string.Equals(i.Id, id, StringComparison.OrdinalIgnoreCase));

    private static string UniqueBase(string folder, string name)
    {
        var safe = string.Concat(name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
        var basePath = Path.Combine(folder, safe);
        var n = 2;
        while (File.Exists(basePath + "." + NestDocument.FileExtension) || File.Exists(basePath + ".png") || File.Exists(basePath + ".mp4"))
            basePath = Path.Combine(folder, $"{safe} {n++}");
        return basePath;
    }

    /// <summary>Stores a fresh capture and returns its item (newest first in the strip).</summary>
    public Item AddCapture(SKBitmap image, double scale, IReadOnlyList<Annotation>? annotations = null, string? name = null)
    {
        var defaults = AppSettings.Shared.DefaultEffects(scale);
        annotations ??= [];
        var doc = ImageCodec.MakeDocument(image, scale, annotations, defaults.IsEmpty ? null : defaults);
        // What the capture looks like: the frame and any layers burned in.
        var rendered = doc.ImagePng;
        if (!defaults.IsEmpty || annotations.Count > 0)
        {
            using var flat = new AnnotationRenderer(scale).Flatten(image, annotations, defaults);
            rendered = ImageCodec.Encode(flat, ExportFormat.Png, scale);
        }
        var stem = name ?? CaptureNaming.TimestampedName();
        var item = WithFallback(folder =>
        {
            var basePath = UniqueBase(folder, stem);
            var docPath = basePath + "." + NestDocument.FileExtension;
            doc.Save(docPath);
            string? pngPath = null;
            if (AppSettings.Shared.KeepPng)
            {
                pngPath = basePath + ".png";
                File.WriteAllBytes(pngPath, rendered);
            }
            return new Item(basePath, Path.GetFileName(basePath), docPath, pngPath, null, DateTime.Now);
        });
        Items.Insert(externals.Count, item);
        thumbnails[item.Id] = MakeThumbnail(rendered);
        Changed?.Invoke();
        return item;
    }

    /// <summary>Moves a finished recording into the captures folder.</summary>
    public Item AddRecording(string tempPath, string? name = null)
    {
        var stem = name ?? CaptureNaming.TimestampedName();
        var item = WithFallback(folder =>
        {
            var basePath = UniqueBase(folder, stem);
            var path = basePath + Path.GetExtension(tempPath);
            File.Copy(tempPath, path);
            return new Item(basePath, Path.GetFileName(basePath), basePath + "." + NestDocument.FileExtension, null, path, DateTime.Now);
        });
        try { File.Delete(tempPath); } catch { }
        Items.Insert(externals.Count, item);
        Changed?.Invoke();
        return item;
    }

    /// <summary>Opening an image from elsewhere copies it into the library so edits never touch the original.</summary>
    public Item ImportImage(string path)
    {
        var decoded = ImageCodec.Load(path) ?? throw new InvalidDataException($"Couldn't read {Path.GetFileName(path)} as an image.");
        using var bitmap = decoded.Bitmap;
        return AddCapture(bitmap, decoded.Scale, name: Path.GetFileNameWithoutExtension(path));
    }

    /// <summary>A .rasternest document: library ones map to their item; others are edited in place.</summary>
    public Item ItemForDocument(string path)
    {
        var key = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, Path.GetFileNameWithoutExtension(path));
        if (Find(key) is { } existing) return existing;
        var item = new Item(key, Path.GetFileName(key), path, null, null, DateTime.Now, IsExternal: true);
        externals.RemoveAll(i => string.Equals(i.Id, key, StringComparison.OrdinalIgnoreCase));
        externals.Insert(0, item);
        Items = [.. externals, .. Items.Where(i => !i.IsExternal)];
        Changed?.Invoke();
        return item;
    }

    public (SKBitmap Image, double Scale, List<Annotation> Annotations, CanvasEffects Effects) Load(Item item)
    {
        if (item.HasDocument)
        {
            var (doc, bitmap) = ImageCodec.LoadDocument(item.DocumentPath);
            return (bitmap, doc.PixelScale, doc.Annotations, doc.Effects ?? CanvasEffects.None);
        }
        if (item.ImagePath != null && ImageCodec.Load(item.ImagePath) is { } loaded)
            return (loaded.Bitmap, loaded.Scale, [], CanvasEffects.None);
        throw new FileNotFoundException($"{item.Name} is missing.", item.DocumentPath);
    }

    /// <summary>Saves the editable document and refreshes the PNG beside it.</summary>
    public void Save(Item item, NestDocument doc, SKImage rendered)
    {
        doc.Save(item.DocumentPath);
        var png = ImageCodec.Encode(rendered, ExportFormat.Png, doc.PixelScale);
        if (!item.IsExternal && (AppSettings.Shared.KeepPng || item.ImagePath != null))
            File.WriteAllBytes(item.ImagePath ?? Path.ChangeExtension(item.DocumentPath, ".png"), png);
        thumbnails[item.Id] = MakeThumbnail(png);
        Reload();
    }

    public void Delete(Item item)
    {
        foreach (var p in new[] { item.DocumentPath, item.ImagePath, item.VideoPath })
            if (p != null && File.Exists(p) && !item.IsExternal)
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(p, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                                                                   Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        externals.RemoveAll(i => i.Id == item.Id);
        thumbnails.Remove(item.Id);
        Reload();
    }

    /// <summary>A small PNG (long side 240 px) for the strip and menus.</summary>
    private readonly HashSet<string> pendingVideoThumbnails = [];

    public byte[]? Thumbnail(Item item)
    {
        if (thumbnails.TryGetValue(item.Id, out var t)) return t;
        if (item.VideoPath is { } video)
        {
            // Read a frame in the background, then refresh the strip.
            if (pendingVideoThumbnails.Add(item.Id)) _ = VideoThumbnail(item.Id, video);
            return null;
        }
        try
        {
            byte[]? source = null;
            if (item.ImagePath != null) source = File.ReadAllBytes(item.ImagePath);
            else if (item.HasDocument)
            {
                var doc = NestDocument.Load(item.DocumentPath);
                if (doc.Annotations.Count > 0 || doc.Effects is { IsEmpty: false })
                {
                    var bmp = ImageCodec.Decode(doc.ImagePng)!.Value.Bitmap;
                    using (bmp)
                    using (var flat = new AnnotationRenderer(doc.PixelScale).Flatten(bmp, doc.Annotations, doc.Effects))
                        source = ImageCodec.Encode(flat, ExportFormat.Png, 1);
                }
                else source = doc.ImagePng;
            }
            if (source == null) return null;
            return thumbnails[item.Id] = MakeThumbnail(source);
        }
        catch { return null; }
    }

    private async Task VideoThumbnail(string id, string video)
    {
        try
        {
            var frames = await RasterNest.Windows.VideoFrames.OpenAsync(video);
            var (w, h) = frames.Size;
            var k = Math.Min(1, 240.0 / Math.Max(w, h));
            using var frame = await frames.FrameAsync(TimeSpan.FromMilliseconds(Math.Min(500, frames.Duration.TotalMilliseconds / 2)),
                                                      Math.Max(1, (int)(w * k)), Math.Max(1, (int)(h * k)));
            using var image = SKImage.FromBitmap(frame);
            thumbnails[id] = image.Encode(SKEncodedImageFormat.Png, 100).ToArray();
            Changed?.Invoke();
        }
        catch { /* no thumbnail; the name still shows */ }
    }

    private static byte[] MakeThumbnail(byte[] png)
    {
        using var bitmap = SKBitmap.Decode(png);
        if (bitmap == null) return png;
        var k = Math.Min(1, 240.0 / Math.Max(bitmap.Width, bitmap.Height));
        using var small = bitmap.Resize(new SKImageInfo(Math.Max(1, (int)(bitmap.Width * k)), Math.Max(1, (int)(bitmap.Height * k))),
                                        new SKSamplingOptions(SKCubicResampler.Mitchell));
        using var image = SKImage.FromBitmap(small ?? bitmap);
        return image.Encode(SKEncodedImageFormat.Png, 100).ToArray();
    }
}
