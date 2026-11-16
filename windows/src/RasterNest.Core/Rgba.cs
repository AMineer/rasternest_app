using System.Text.Json.Serialization;

namespace RasterNest.Core;

/// <summary>A platform-neutral sRGB color with components in 0…1. JSON keys: r, g, b, a.</summary>
public readonly record struct Rgba(
    [property: JsonPropertyName("r")] double R,
    [property: JsonPropertyName("g")] double G,
    [property: JsonPropertyName("b")] double B,
    [property: JsonPropertyName("a")] double A = 1)
{
    public Rgba WithAlpha(double alpha) => this with { A = alpha };

    /// <summary>Relative luminance (approximate, sRGB weights).</summary>
    [JsonIgnore] public double Luminance => 0.2126 * R + 0.7152 * G + 0.0722 * B;

    /// <summary>True when dark text reads better than white text on top of this color.</summary>
    [JsonIgnore] public bool PrefersDarkText => Luminance > 0.6;

    public static readonly Rgba Red = new(0.94, 0.23, 0.20);
    public static readonly Rgba Orange = new(0.98, 0.55, 0.12);
    public static readonly Rgba Yellow = new(1.0, 0.86, 0.10);
    public static readonly Rgba Green = new(0.20, 0.72, 0.35);
    public static readonly Rgba Blue = new(0.055, 0.647, 0.914);   // brand sky #0EA5E9
    public static readonly Rgba Purple = new(0.486, 0.227, 0.929); // brand violet #7C3AED
    public static readonly Rgba Black = new(0.08, 0.08, 0.09);
    public static readonly Rgba White = new(1, 1, 1);

    public static readonly IReadOnlyList<Rgba> Palette = [Red, Orange, Yellow, Green, Blue, Purple, Black, White];

    /// <summary>"#RRGGBB" (alpha dropped).</summary>
    [JsonIgnore]
    public string Hex => $"#{Byte(R):X2}{Byte(G):X2}{Byte(B):X2}";

    private static int Byte(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255, MidpointRounding.AwayFromZero);
}
