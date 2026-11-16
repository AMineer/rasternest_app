namespace RasterNest.Core;

public enum CombineArrangement { Horizontal, Vertical, Grid }

/// <summary>
/// Where each image goes when several are combined into one (side by side, stacked or a grid).
/// Pure geometry so it's shared by the app, <c>rnest combine</c> and tests.
/// </summary>
public sealed record CombineLayout
{
    public CombineArrangement Arrangement { get; init; } = CombineArrangement.Horizontal;
    /// <summary>Space between images, in output pixels.</summary>
    public double Gap { get; init; } = 24;
    /// <summary>Space around the outside, in output pixels.</summary>
    public double Padding { get; init; }
    /// <summary>Grid columns; null picks a near-square grid.</summary>
    public int? Columns { get; init; }
    /// <summary>Scale images so rows share a height, columns share a width, or every image fills the same cell.</summary>
    public bool MatchSizes { get; init; } = true;

    public static string Title(CombineArrangement a) => a switch
    {
        CombineArrangement.Horizontal => "Side by Side",
        CombineArrangement.Vertical => "Stacked",
        _ => "Grid",
    };

    public sealed record Result(SizeD Canvas, IReadOnlyList<RectD> Frames);

    /// <summary>Frames (origin top-left) for images of the given pixel sizes.</summary>
    public Result Place(IReadOnlyList<SizeD> input)
    {
        var sizes = input.Select(s => new SizeD(Math.Max(1, s.Width), Math.Max(1, s.Height))).ToList();
        if (sizes.Count == 0) return new Result(SizeD.Zero, []);
        var frames = new List<RectD>();

        switch (Arrangement)
        {
            case CombineArrangement.Horizontal:
            {
                var h = MatchSizes ? sizes.Max(s => s.Height) : 0;
                var scaled = sizes.Select(s => MatchSizes ? new SizeD(s.Width * h / s.Height, h) : s).ToList();
                var rowH = scaled.Max(s => s.Height);
                var x = Padding;
                foreach (var s in scaled)
                {
                    frames.Add(new RectD(x, Padding + (rowH - s.Height) / 2, s.Width, s.Height));
                    x += s.Width + Gap;
                }
                return new Result(new SizeD(x - Gap + Padding, rowH + Padding * 2), frames.Select(f => f.Integral).ToList());
            }
            case CombineArrangement.Vertical:
            {
                var w = MatchSizes ? sizes.Max(s => s.Width) : 0;
                var scaled = sizes.Select(s => MatchSizes ? new SizeD(w, s.Height * w / s.Width) : s).ToList();
                var colW = scaled.Max(s => s.Width);
                var y = Padding;
                foreach (var s in scaled)
                {
                    frames.Add(new RectD(Padding + (colW - s.Width) / 2, y, s.Width, s.Height));
                    y += s.Height + Gap;
                }
                return new Result(new SizeD(colW + Padding * 2, y - Gap + Padding), frames.Select(f => f.Integral).ToList());
            }
            default:
            {
                var cols = Math.Max(1, Math.Min(Columns ?? (int)Math.Ceiling(Math.Sqrt(sizes.Count)), sizes.Count));
                var rows = (int)Math.Ceiling((double)sizes.Count / cols);
                var cell = new SizeD(sizes.Max(s => s.Width), sizes.Max(s => s.Height));
                for (var i = 0; i < sizes.Count; i++)
                {
                    var s = sizes[i];
                    int col = i % cols, row = i / cols;
                    var ox = Padding + col * (cell.Width + Gap);
                    var oy = Padding + row * (cell.Height + Gap);
                    // Fit inside the cell keeping aspect ratio; only grow when matching sizes.
                    var f = Math.Min(cell.Width / s.Width, cell.Height / s.Height);
                    if (!MatchSizes) f = Math.Min(f, 1);
                    double fw = s.Width * f, fh = s.Height * f;
                    frames.Add(new RectD(ox + (cell.Width - fw) / 2, oy + (cell.Height - fh) / 2, fw, fh));
                }
                var canvas = new SizeD(cols * cell.Width + (cols - 1) * Gap + Padding * 2, rows * cell.Height + (rows - 1) * Gap + Padding * 2);
                return new Result(canvas, frames.Select(f => f.Integral).ToList());
            }
        }
    }
}
