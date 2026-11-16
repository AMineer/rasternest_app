using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RasterNest.Core;

/// <summary>A box in image pixels, origin top-left, y down. Written as whole numbers for readable JSON.</summary>
[JsonConverter(typeof(PixelBoxConverter))]
public readonly record struct PixelBox(double X, double Y, double Width, double Height)
{
    public PixelBox(RectD r) : this(r.MinX, r.MinY, r.Width, r.Height) { }

    public RectD Rect => new(X, Y, Width, Height);
    public PointD Center => new(X + Width / 2, Y + Height / 2);

    public static PixelBox? Union(IEnumerable<PixelBox> boxes)
    {
        RectD? r = null;
        foreach (var b in boxes) r = r is { } u ? u.Union(b.Rect) : b.Rect;
        return r is { } x ? new PixelBox(x) : null;
    }
}

internal sealed class PixelBoxConverter : JsonConverter<PixelBox>
{
    public override PixelBox Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        double x = 0, y = 0, w = 0, h = 0;
        if (r.TokenType != JsonTokenType.StartObject) throw new JsonException("A box is {x, y, width, height}.");
        while (r.Read() && r.TokenType != JsonTokenType.EndObject)
        {
            var name = r.GetString(); r.Read();
            switch (name)
            {
                case "x": x = RasterNestJson.ReadNumber(ref r); break;
                case "y": y = RasterNestJson.ReadNumber(ref r); break;
                case "width": w = RasterNestJson.ReadNumber(ref r); break;
                case "height": h = RasterNestJson.ReadNumber(ref r); break;
                default: r.Skip(); break;
            }
        }
        return new PixelBox(x, y, w, h);
    }

    public override void Write(Utf8JsonWriter w, PixelBox v, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        w.WriteNumber("x", (long)Math.Round(v.X, MidpointRounding.AwayFromZero));
        w.WriteNumber("y", (long)Math.Round(v.Y, MidpointRounding.AwayFromZero));
        w.WriteNumber("width", (long)Math.Round(v.Width, MidpointRounding.AwayFromZero));
        w.WriteNumber("height", (long)Math.Round(v.Height, MidpointRounding.AwayFromZero));
        w.WriteEndObject();
    }
}

/// <summary>One recognized word.</summary>
public sealed record TextWord(string Text, PixelBox Box);

/// <summary>One recognized line of text with its words.</summary>
[JsonConverter(typeof(TextLineConverter))]
public sealed record TextLine(string Text, double Confidence, PixelBox Box, IReadOnlyList<TextWord> Words);

internal sealed class TextLineConverter : JsonConverter<TextLine>
{
    public override TextLine Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        using var doc = JsonDocument.ParseValue(ref r);
        var e = doc.RootElement;
        var text = e.GetProperty("text").GetString() ?? "";
        var conf = e.TryGetProperty("confidence", out var c) ? c.GetDouble() : 1;
        var box = e.GetProperty("box").Deserialize<PixelBox>(o);
        var words = e.TryGetProperty("words", out var w) ? w.Deserialize<List<TextWord>>(o) ?? [] : [];
        return new TextLine(text, conf, box, words);
    }

    public override void Write(Utf8JsonWriter w, TextLine v, JsonSerializerOptions o)
    {
        w.WriteStartObject();
        w.WriteString("text", v.Text);
        w.WriteNumber("confidence", Math.Round(v.Confidence * 100, MidpointRounding.AwayFromZero) / 100);
        w.WritePropertyName("box");
        JsonSerializer.Serialize(w, v.Box, o);
        if (v.Words.Count > 0)
        {
            w.WritePropertyName("words");
            JsonSerializer.Serialize(w, v.Words, o);
        }
        w.WriteEndObject();
    }
}

/// <summary>Everything <c>rnest ocr --json</c> prints.</summary>
public sealed record OcrResult(int Width, int Height, double Scale, IReadOnlyList<TextLine> Lines)
{
    [JsonIgnore] public string Text => string.Join("\n", Lines.Select(l => l.Text));
}

/// <summary>Finds text on an image: phrases for annotation anchors, patterns for redaction.</summary>
public static class TextMatcher
{
    /// <summary>
    /// The box of the occurrence-th (1-based) place the phrase appears, matched case-insensitively.
    /// Exact whole-line matches win over matches inside a longer line.
    /// </summary>
    public static PixelBox? Find(string phrase, IReadOnlyList<TextLine> lines, int occurrence = 1)
    {
        var all = Matches(phrase, lines);
        var index = Math.Max(1, occurrence) - 1;
        return index < all.Count ? all[index] : null;
    }

    /// <summary>Every place the phrase appears, best matches first, then top-to-bottom, left-to-right.</summary>
    public static List<PixelBox> Matches(string phrase, IReadOnlyList<TextLine> lines)
    {
        var needle = Normalize(phrase);
        if (needle.Length == 0) return [];
        List<PixelBox> exact = [], wordExact = [], partial = [];
        var target = needle.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var line in ReadingOrder(lines))
        {
            var normLine = Normalize(line.Text);
            if (normLine == needle) { exact.Add(line.Box); continue; }
            // A run of whole words that spells the phrase.
            var words = line.Words.Select(w => Normalize(w.Text)).ToArray();
            var found = false;
            if (target.Length > 0 && words.Length >= target.Length)
            {
                for (var i = 0; i <= words.Length - target.Length; i++)
                {
                    if (!words.AsSpan(i, target.Length).SequenceEqual(target)) continue;
                    if (PixelBox.Union(line.Words.Skip(i).Take(target.Length).Select(w => w.Box)) is { } box) wordExact.Add(box);
                    found = true;
                }
            }
            if (found) continue;
            if (normLine.Contains(needle, StringComparison.Ordinal))
                partial.Add(BoxesCovering(needle, line) ?? line.Box);
        }
        return [.. exact, .. wordExact, .. partial];
    }

    /// <summary>Boxes of every match of a regular expression, one box per match (covering the words it touches).</summary>
    public static List<PixelBox> Boxes(Regex regex, IReadOnlyList<TextLine> lines)
    {
        var output = new List<PixelBox>();
        foreach (var line in ReadingOrder(lines))
        {
            var (joined, ranges) = JoinedWords(line);
            foreach (Match m in regex.Matches(joined))
            {
                if (m.Length == 0) continue;
                var touched = line.Words.Zip(ranges).Where(p => Overlaps(p.Second, m.Index, m.Length)).Select(p => p.First.Box);
                if (PixelBox.Union(touched) is { } box) output.Add(box);
                else if (line.Words.Count == 0) output.Add(line.Box);
            }
        }
        return output;
    }

    internal static string Normalize(string s)
    {
        var lower = s.ToLowerInvariant().Replace("…", "...");
        var collapsed = string.Join(' ', lower.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        // Bullets, icons OCR'd as symbols, trailing colons and ellipses don't count.
        int start = 0, end = collapsed.Length;
        while (start < end && !IsAlphanumeric(collapsed[start])) start++;
        while (end > start && !IsAlphanumeric(collapsed[end - 1])) end--;
        return collapsed[start..end];
    }

    private static bool IsAlphanumeric(char c) =>
        char.IsLetterOrDigit(c) || char.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
            or UnicodeCategory.EnclosingMark or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;

    public static List<TextLine> ReadingOrder(IEnumerable<TextLine> lines) =>
        lines.OrderBy(l => l, Comparer<TextLine>.Create((a, b) =>
        {
            // Same visual row if their vertical centers are within half a line height.
            var tolerance = Math.Min(a.Box.Height, b.Box.Height) / 2;
            if (Math.Abs(a.Box.Center.Y - b.Box.Center.Y) > tolerance) return a.Box.Center.Y.CompareTo(b.Box.Center.Y);
            return a.Box.X.CompareTo(b.Box.X);
        })).ToList();

    /// <summary>The line's words joined by single spaces, plus each word's (start, length) in that string.</summary>
    internal static (string, List<(int Start, int Length)>) JoinedWords(TextLine line)
    {
        if (line.Words.Count == 0) return (line.Text, []);
        var sb = new StringBuilder();
        var ranges = new List<(int, int)>();
        foreach (var w in line.Words)
        {
            if (sb.Length > 0) sb.Append(' ');
            ranges.Add((sb.Length, w.Text.Length));
            sb.Append(w.Text);
        }
        return (sb.ToString(), ranges);
    }

    private static bool Overlaps((int Start, int Length) r, int start, int length) =>
        Math.Max(r.Start, start) < Math.Min(r.Start + r.Length, start + length);

    private static PixelBox? BoxesCovering(string needle, TextLine line)
    {
        var (joined, ranges) = JoinedWords(line);
        var at = joined.ToLowerInvariant().IndexOf(needle, StringComparison.Ordinal);
        if (at < 0) return null;
        return PixelBox.Union(line.Words.Zip(ranges).Where(p => Overlaps(p.Second, at, needle.Length)).Select(p => p.First.Box));
    }
}

/// <summary>Built-in patterns for redact annotations.</summary>
public static class RedactionPattern
{
    public static readonly IReadOnlyDictionary<string, Regex> All = new Dictionary<string, Regex>
    {
        ["email"] = new(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"),
        ["phone"] = new(@"(?:\+?\d{1,3}[\s.\-]?)?(?:\(\d{3}\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4}"),
        ["ipv4"] = new(@"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
        ["url"] = new(@"https?://\S+"),
        ["card"] = new(@"\b(?:\d[ \-]?){13,19}\b"),
        // Long opaque strings: API keys, tokens, hashes.
        ["token"] = new(@"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"),
    };

    public static Regex? Named(string name) => All.TryGetValue(name.ToLowerInvariant(), out var r) ? r : null;
}
