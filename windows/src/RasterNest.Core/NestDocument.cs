using System.Text.Json;
using System.Text.Json.Serialization;

namespace RasterNest.Core;

public sealed class UnsupportedVersionException(int version)
    : Exception($"This file was made by a newer version of RasterNest (format {version}). Update RasterNest to open it.")
{
    public int Version { get; } = version;
}

/// <summary>
/// Editable capture: the original image plus its annotations (the .rasternest file format).
/// Plain JSON with the PNG embedded as base64; byte-compatible with the Mac and Linux apps.
/// </summary>
public sealed class NestDocument
{
    public const string FileExtension = "rasternest";
    public const int CurrentFormatVersion = 2;

    public int FormatVersion { get; set; } = 1;
    [JsonPropertyName("imagePNG")] public byte[] ImagePng { get; set; } = [];
    /// <summary>Pixels per point of the original capture (2 for Retina, 1.5 for 150% Windows scaling).</summary>
    public double PixelScale { get; set; } = 1;
    public List<Annotation> Annotations { get; set; } = [];
    /// <summary>Frame around the capture. Absent in files from 0.3 and earlier.</summary>
    public CanvasEffects? Effects { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    public NestDocument() { }

    public NestDocument(byte[] imagePng, double pixelScale, IEnumerable<Annotation> annotations, CanvasEffects? effects = null,
                        DateTimeOffset? createdAt = null)
    {
        ImagePng = imagePng;
        PixelScale = pixelScale;
        Annotations = annotations.ToList();
        Effects = effects;
        CreatedAt = createdAt ?? DateTimeOffset.UtcNow;
    }

    /// <summary>
    /// Version 2 adds image layers. Files without them stay version 1 so older apps still open them;
    /// files with them are marked 2 so older apps say "needs a newer version" instead of failing oddly.
    /// </summary>
    public byte[] Encoded()
    {
        var version = FormatVersion;
        if (version <= CurrentFormatVersion)
            version = Annotations.Any(a => a.Kind == AnnotationKind.Image) ? 2 : 1;
        var saved = FormatVersion;
        FormatVersion = version;
        try { return JsonSerializer.SerializeToUtf8Bytes(this, RasterNestJson.Options); }
        finally { FormatVersion = saved; }
    }

    public static NestDocument Decoded(ReadOnlySpan<byte> data)
    {
        var doc = RasterNestJson.Deserialize<NestDocument>(data);
        if (doc.FormatVersion > CurrentFormatVersion) throw new UnsupportedVersionException(doc.FormatVersion);
        return doc;
    }

    public static NestDocument Load(string path) => Decoded(File.ReadAllBytes(path));

    public void Save(string path)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, Encoded());
        File.Move(tmp, path, overwrite: true);
    }
}
