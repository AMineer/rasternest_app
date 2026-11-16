using System.Text.Json.Serialization;

namespace RasterNest.Core;

[JsonConverter(typeof(JsonStringEnumConverter<FrameBackground>))]
public enum FrameBackground
{
    [JsonStringEnumMemberName("none")] None,
    [JsonStringEnumMemberName("solid")] Solid,
    [JsonStringEnumMemberName("gradient")] Gradient,
}

/// <summary>
/// A frame around a capture: padding, background, rounded corners, drop shadow and border.
/// Sizes are in image pixels. Stored in .rasternest files (optional, so older files still open).
/// </summary>
public sealed record CanvasEffects
{
    public double Padding { get; set; }
    public FrameBackground Background { get; set; } = FrameBackground.None;
    public Rgba BackgroundColor { get; set; } = new(0.973, 0.980, 0.988);
    /// <summary>Second gradient color (top-left → bottom-right).</summary>
    public Rgba BackgroundColor2 { get; set; } = new(0.886, 0.910, 0.941);
    public double CornerRadius { get; set; }
    public bool Shadow { get; set; }
    public double BorderWidth { get; set; }
    public Rgba BorderColor { get; set; } = new(0.886, 0.910, 0.941);

    public static CanvasEffects None => new();

    /// <summary>A clean "docs" look scaled for the image's pixel density.</summary>
    public static CanvasEffects Documentation(double scale) => new()
    {
        Padding = 32 * scale,
        Background = FrameBackground.Gradient,
        BackgroundColor = new Rgba(0.929, 0.914, 0.996),
        BackgroundColor2 = new Rgba(0.878, 0.949, 0.996),
        CornerRadius = 10 * scale,
        Shadow = true,
        BorderWidth = 0,
    };

    [JsonIgnore] public bool IsEmpty => Padding <= 0 && CornerRadius <= 0 && !Shadow && BorderWidth <= 0;

    /// <summary>Size of the framed result for an image of <paramref name="size"/>.</summary>
    public SizeD OutputSize(SizeD size) => new(size.Width + Padding * 2, size.Height + Padding * 2);
}
