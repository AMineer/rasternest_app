using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RasterNest.Core;

/// <summary>
/// JSON settings that read and write exactly what the Swift (Mac/Linux) side does:
/// camelCase keys, absent optionals omitted, points as [x, y], dates as "2026-11-16T19:34:46Z",
/// UUIDs upper-case and PNGs as base64.
/// </summary>
public static class RasterNestJson
{
    public static readonly JsonSerializerOptions Options = Create(indented: false);
    public static readonly JsonSerializerOptions Pretty = Create(indented: true);

    private static JsonSerializerOptions Create(bool indented)
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            WriteIndented = indented,
            NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        };
        o.Converters.Add(new PointConverter());
        o.Converters.Add(new SizeConverter());
        o.Converters.Add(new SwiftDateConverter());
        o.Converters.Add(new UpperGuidConverter());
        o.MakeReadOnly(populateMissingResolver: true);
        return o;
    }

    public static string Serialize<T>(T value, bool pretty = false) =>
        JsonSerializer.Serialize(value, pretty ? Pretty : Options);

    public static T Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options) ?? throw new JsonException("Empty JSON.");

    public static T Deserialize<T>(ReadOnlySpan<byte> utf8) =>
        JsonSerializer.Deserialize<T>(utf8, Options) ?? throw new JsonException("Empty JSON.");

    internal static double ReadNumber(ref Utf8JsonReader r) => r.TokenType switch
    {
        JsonTokenType.Number => r.GetDouble(),
        JsonTokenType.String when double.TryParse(r.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => throw new JsonException("Expected a number."),
    };

    internal static void WriteNumber(Utf8JsonWriter w, double v)
    {
        // Whole numbers without ".0", like Swift's encoder.
        if (Math.Abs(v) < 1e15 && v == Math.Floor(v)) w.WriteNumberValue((long)v);
        else w.WriteNumberValue(v);
    }

    private sealed class PointConverter : JsonConverter<PointD>
    {
        public override PointD Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
        {
            if (r.TokenType == JsonTokenType.StartArray)
            {
                r.Read(); var x = ReadNumber(ref r);
                r.Read(); var y = ReadNumber(ref r);
                r.Read();
                if (r.TokenType != JsonTokenType.EndArray) throw new JsonException("A point is [x, y].");
                return new PointD(x, y);
            }
            // Also accept {"x":…, "y":…}.
            double px = 0, py = 0;
            if (r.TokenType != JsonTokenType.StartObject) throw new JsonException("A point is [x, y].");
            while (r.Read() && r.TokenType != JsonTokenType.EndObject)
            {
                var name = r.GetString(); r.Read();
                if (name == "x") px = ReadNumber(ref r); else if (name == "y") py = ReadNumber(ref r); else r.Skip();
            }
            return new PointD(px, py);
        }

        public override void Write(Utf8JsonWriter w, PointD v, JsonSerializerOptions o)
        {
            w.WriteStartArray(); WriteNumber(w, v.X); WriteNumber(w, v.Y); w.WriteEndArray();
        }
    }

    private sealed class SizeConverter : JsonConverter<SizeD>
    {
        public override SizeD Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
        {
            if (r.TokenType != JsonTokenType.StartArray) throw new JsonException("A size is [width, height].");
            r.Read(); var w = ReadNumber(ref r);
            r.Read(); var h = ReadNumber(ref r);
            r.Read();
            return new SizeD(w, h);
        }

        public override void Write(Utf8JsonWriter w, SizeD v, JsonSerializerOptions o)
        {
            w.WriteStartArray(); WriteNumber(w, v.Width); WriteNumber(w, v.Height); w.WriteEndArray();
        }
    }

    /// <summary>Swift's .iso8601 strategy: whole seconds, UTC, "Z". Reading also accepts fractions and offsets.</summary>
    private sealed class SwiftDateConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) =>
            DateTimeOffset.Parse(r.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

        public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o) =>
            w.WriteStringValue(v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    private sealed class UpperGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => Guid.Parse(r.GetString()!);
        public override void Write(Utf8JsonWriter w, Guid v, JsonSerializerOptions o) => w.WriteStringValue(v.ToString("D").ToUpperInvariant());
    }
}
