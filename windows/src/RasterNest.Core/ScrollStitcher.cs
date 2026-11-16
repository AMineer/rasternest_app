namespace RasterNest.Core;

/// <summary>
/// A compact fingerprint of a frame: for every pixel row, the mean brightness of <see cref="Bands"/> vertical bands.
/// Comparing fingerprints is far cheaper than comparing pixels.
/// </summary>
public sealed class RowSignature
{
    public int Rows { get; }
    public int Bands { get; }
    /// <summary>Rows × Bands values in 0…255, row-major.</summary>
    public float[] Values { get; }

    public RowSignature(int rows, int bands, float[] values)
    {
        if (values.Length != rows * bands) throw new ArgumentException("values must hold rows * bands entries");
        Rows = rows; Bands = bands; Values = values;
    }

    /// <summary>Mean absolute difference between row r of this and row s of other.</summary>
    internal float RowDistance(int r, RowSignature other, int s)
    {
        float sum = 0;
        int a = r * Bands, b = s * other.Bands;
        for (var i = 0; i < Bands; i++) sum += Math.Abs(Values[a + i] - other.Values[b + i]);
        return sum / Bands;
    }

    /// <summary>Builds a signature from 32-bit BGRA or RGBA pixels (alpha ignored).</summary>
    public static RowSignature FromPixels(ReadOnlySpan<byte> pixels, int width, int height, int stride, int bands = 16)
    {
        var values = new float[height * bands];
        var bandWidth = Math.Max(1, width / bands);
        for (var y = 0; y < height; y++)
        {
            var row = pixels.Slice(y * stride, Math.Min(stride, pixels.Length - y * stride));
            for (var band = 0; band < bands; band++)
            {
                int x0 = band * bandWidth, x1 = band == bands - 1 ? width : Math.Min(width, x0 + bandWidth);
                float sum = 0;
                var step = Math.Max(1, (x1 - x0) / 32);
                var n = 0;
                for (var x = x0; x < x1; x += step)
                {
                    var i = x * 4;
                    sum += (row[i] + row[i + 1] + row[i + 2]) / 3f;
                    n++;
                }
                values[y * bands + band] = n > 0 ? sum / n : 0;
            }
        }
        return new RowSignature(height, bands, values);
    }
}

/// <summary>Works out how a scrolling region moved between frames.</summary>
public static class ScrollMatcher
{
    /// <summary>Rows at the top and bottom that are unchanged between two frames (sticky headers/footers). Capped at 40% each.</summary>
    public static (int Top, int Bottom) StaticEdges(RowSignature a, RowSignature b, float tolerance)
    {
        var cap = (int)(a.Rows * 0.4);
        var top = 0;
        while (top < cap && a.RowDistance(top, b, top) <= tolerance) top++;
        var bottom = 0;
        while (bottom < cap && a.RowDistance(a.Rows - 1 - bottom, b, a.Rows - 1 - bottom) <= tolerance) bottom++;
        return (top, bottom);
    }

    /// <summary>
    /// How many pixels the content moved up from previous to current, comparing only rows in [top, rows - bottom).
    /// Null when no offset matches confidently; 0 when nothing moved.
    /// </summary>
    public static int? Offset(RowSignature previous, RowSignature current, int top, int bottom,
                              double minOverlapFraction = 0.2, float tolerance = 3)
    {
        var body = previous.Rows - top - bottom;
        var minOverlap = Math.Max(8, (int)(body * minOverlapFraction));
        if (body <= minOverlap) return null;
        var maxShift = body - minOverlap;

        var costs = new float[maxShift + 1];
        Array.Fill(costs, float.PositiveInfinity);
        var best = float.PositiveInfinity;
        for (var dy = 0; dy <= maxShift; dy++)
        {
            var overlap = body - dy;
            var stride = Math.Max(1, overlap / 300);
            float sum = 0, count = 0;
            for (var r = 0; r < overlap; r += stride)
            {
                sum += current.RowDistance(top + r, previous, top + r + dy);
                count++;
                if (count >= 24 && sum / count > best * 4 + tolerance * 4) { sum = float.PositiveInfinity; break; }
            }
            var cost = sum / Math.Max(count, 1);
            costs[dy] = cost;
            best = Math.Min(best, cost);
        }
        if (!(best <= tolerance)) return null;
        // Prefer the smallest shift that is about as good as the best one.
        var slack = Math.Max(tolerance * 0.35f, best * 0.5f);
        var index = Array.FindIndex(costs, c => c <= best + slack);
        return index >= 0 ? index : null;
    }
}

public abstract record StitchStep
{
    /// <summary>The first frame: keep all of it.</summary>
    public sealed record First : StitchStep;
    /// <summary>Keep Count rows of this frame starting at row From.</summary>
    public sealed record Append(int From, int Count) : StitchStep;
    /// <summary>Nothing new (no movement, scrolled up, or no confident match).</summary>
    public sealed record Skip : StitchStep;
}

/// <summary>
/// Decides, frame by frame, which rows to keep to build one tall image: the first frame (minus any sticky footer),
/// then every appended strip, then the sticky footer from the last accepted frame.
/// </summary>
public sealed class ScrollStitcher(float tolerance = 3, double minOverlapFraction = 0.2)
{
    public RowSignature? Reference { get; private set; }
    public int Header { get; private set; }
    public int Footer { get; private set; }
    public bool EdgesLocked { get; private set; }
    /// <summary>Rows in the stitched image so far, not counting the footer added at the end.</summary>
    public int BodyHeight { get; private set; }
    /// <summary>Consecutive frames that changed but couldn't be matched (e.g. scrolling too fast).</summary>
    public int MismatchStreak { get; private set; }

    public int TotalHeight => BodyHeight + Footer;

    public StitchStep Add(RowSignature sig)
    {
        if (Reference is not { } reference)
        {
            Reference = sig;
            BodyHeight = sig.Rows;
            return new StitchStep.First();
        }
        if (sig.Rows != reference.Rows || sig.Bands != reference.Bands) return new StitchStep.Skip();

        int top = Header, bottom = Footer;
        if (!EdgesLocked)
        {
            var edges = ScrollMatcher.StaticEdges(reference, sig, tolerance * 0.5f);
            if (edges.Top + edges.Bottom >= sig.Rows - 8) return new StitchStep.Skip(); // identical frame
            top = edges.Top;
            bottom = edges.Bottom;
        }

        if (ScrollMatcher.Offset(reference, sig, top, bottom, minOverlapFraction, tolerance) is not { } dy)
        {
            MismatchStreak++;
            return new StitchStep.Skip();
        }
        MismatchStreak = 0;
        if (dy <= 0) return new StitchStep.Skip();

        if (!EdgesLocked)
        {
            Header = top;
            Footer = bottom;
            EdgesLocked = true;
            // The first frame's footer rows move to the very end of the image.
            BodyHeight = reference.Rows - Footer;
        }
        Reference = sig;
        BodyHeight += dy;
        return new StitchStep.Append(sig.Rows - Footer - dy, dy);
    }
}
