using RasterNest.Core;

namespace RasterNest.Core.Tests;

/// <summary>
/// Simulates a scrolling window over a tall page whose rows have unique fingerprints, then checks that the
/// stitched output (as row identities) is the page exactly once, in order.
/// </summary>
public class ScrollStitcherTests
{
    private const int Bands = 8;
    private const int FrameRows = 240;

    private static float[][] Page(int rows, ulong seed)
    {
        var state = seed;
        float Next()
        {
            unchecked { state = state * 6364136223846793005UL + 1442695040888963407UL; }
            return (state >> 33) % 256;
        }
        return Enumerable.Range(0, rows).Select(_ => Enumerable.Range(0, Bands).Select(_ => Next()).ToArray()).ToArray();
    }

    private sealed record Frame(RowSignature Sig, int[] Ids);

    private static Frame MakeFrame(float[][] page, int offset, float[][]? header = null, float[][]? footer = null)
    {
        header ??= []; footer ??= [];
        var body = FrameRows - header.Length - footer.Length;
        var rows = new List<float[]>(header);
        var ids = new List<int>(Enumerable.Range(0, header.Length).Select(i => -1000 - i));
        rows.AddRange(page.Skip(offset).Take(body));
        ids.AddRange(Enumerable.Range(offset, body));
        rows.AddRange(footer);
        ids.AddRange(Enumerable.Range(0, footer.Length).Select(i => -2000 - i));
        return new Frame(new RowSignature(FrameRows, Bands, rows.SelectMany(r => r).ToArray()), ids.ToArray());
    }

    private static (List<int> Ids, ScrollStitcher Stitcher) Stitch(IEnumerable<Frame> frames)
    {
        var stitcher = new ScrollStitcher();
        int[] first = [], last = [];
        var strips = new List<int>();
        foreach (var f in frames)
        {
            switch (stitcher.Add(f.Sig))
            {
                case StitchStep.First: first = f.Ids; last = f.Ids; break;
                case StitchStep.Append(var from, var count): strips.AddRange(f.Ids.Skip(from).Take(count)); last = f.Ids; break;
            }
        }
        var ids = first.Take(FrameRows - stitcher.Footer).Concat(strips).Concat(last.Skip(FrameRows - stitcher.Footer)).ToList();
        Assert.Equal(stitcher.TotalHeight, ids.Count);
        return (ids, stitcher);
    }

    [Fact]
    public void PlainScrollIncludingPauses()
    {
        var p = Page(2000, 1);
        int[] offsets = [0, 0, 37, 80, 80, 150, 151, 300, 420, 421, 600];
        var (ids, _) = Stitch(offsets.Select(o => MakeFrame(p, o)));
        Assert.Equal(Enumerable.Range(0, 600 + FrameRows), ids);
    }

    [Fact]
    public void StickyHeaderAndFooterAppearOnce()
    {
        var p = Page(2000, 2);
        var header = Page(20, 3);
        var footer = Page(15, 4);
        var body = FrameRows - 35;
        int[] offsets = [0, 40, 90, 160, 161, 230];
        var (ids, stitcher) = Stitch(offsets.Select(o => MakeFrame(p, o, header, footer)));
        Assert.Equal(20, stitcher.Header);
        Assert.Equal(15, stitcher.Footer);
        var expected = Enumerable.Range(0, 20).Select(i => -1000 - i)
            .Concat(Enumerable.Range(0, 230 + body))
            .Concat(Enumerable.Range(0, 15).Select(i => -2000 - i));
        Assert.Equal(expected, ids);
    }

    [Fact]
    public void ScrollingBackUpIsIgnored()
    {
        var p = Page(2000, 5);
        int[] offsets = [0, 60, 120, 70, 20, 90, 180];
        var (ids, _) = Stitch(offsets.Select(o => MakeFrame(p, o)));
        Assert.Equal(Enumerable.Range(0, 180 + FrameRows), ids);
    }

    [Fact]
    public void JumpTooFarIsSkippedAndReported()
    {
        var p = Page(3000, 6);
        var stitcher = new ScrollStitcher();
        Assert.IsType<StitchStep.First>(stitcher.Add(MakeFrame(p, 0).Sig));
        Assert.IsType<StitchStep.Skip>(stitcher.Add(MakeFrame(p, 1000).Sig));
        Assert.Equal(1, stitcher.MismatchStreak);
        Assert.Equal(new StitchStep.Append(FrameRows - 50, 50), stitcher.Add(MakeFrame(p, 50).Sig));
        Assert.Equal(0, stitcher.MismatchStreak);
    }

    [Fact]
    public void IdenticalFramesAreSkipped()
    {
        var p = Page(1000, 7);
        var stitcher = new ScrollStitcher();
        stitcher.Add(MakeFrame(p, 10).Sig);
        Assert.IsType<StitchStep.Skip>(stitcher.Add(MakeFrame(p, 10).Sig));
        Assert.Equal(FrameRows, stitcher.TotalHeight);
    }

    [Fact]
    public void OffsetMatcherFindsExactShiftWithNoise()
    {
        var p = Page(1200, 8);
        var a = MakeFrame(p, 100).Sig;
        var b = MakeFrame(p, 173).Sig;
        for (var i = 0; i < b.Values.Length; i += 7) b.Values[i] += 1.5f;
        Assert.Equal(73, ScrollMatcher.Offset(a, b, 0, 0));
    }
}
