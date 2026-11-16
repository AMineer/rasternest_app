using System.Text.Json.Nodes;
using RasterNest.Core;

namespace RasterNest.Core.Tests;

public class AgentToolsTests
{
    private static TextLine Line(string text, double x, double y, double wordWidth = 40)
    {
        var words = new List<TextWord>();
        var cx = x;
        foreach (var w in text.Split(' '))
        {
            words.Add(new TextWord(w, new PixelBox(cx, y, wordWidth, 20)));
            cx += wordWidth + 10;
        }
        return new TextLine(text, 1, PixelBox.Union(words.Select(w => w.Box))!.Value, words);
    }

    private readonly List<TextLine> screen =
    [
        Line("Save As…", 10, 10),
        Line("Cancel Save", 300, 400),
        Line("• Save", 500, 600),
        Line("Contact: jane.doe@example.com today", 20, 700),
    ];

    [Fact]
    public void ExactLineBeatsPartialMatches()
    {
        Assert.Equal(500, TextMatcher.Find("Save", screen)?.X); // "• Save" normalizes to "save"
        var all = TextMatcher.Matches("save", screen);
        Assert.Equal(3, all.Count);
        Assert.Equal(10, all[1].X);
        Assert.Equal(40, all[1].Width);
        Assert.Equal(350, TextMatcher.Find("Save", screen, 3)?.X);
        Assert.Null(TextMatcher.Find("Delete", screen));
    }

    [Fact]
    public void RedactionCoversOnlyMatchingWords()
    {
        var boxes = TextMatcher.Boxes(RedactionPattern.Named("email")!, screen);
        Assert.Single(boxes);
        Assert.Equal(70, boxes[0].X); // second word
        Assert.Equal(40, boxes[0].Width);
    }

    [Fact]
    public void SpecResolvesStepsArrowsAndRedaction()
    {
        var spec = new AnnotationSpec
        {
            Frame = "docs",
            Annotations =
            [
                new() { Type = "step", At = new() { Text = "Cancel Save" } },
                new() { Type = "step", At = new() { X = 50, Y = 60 } },
                new() { Type = "arrow", To = new() { Text = "Save" } },
                new() { Type = "box", Around = new() { Rect = [1, 2, 30, 40] } },
                new() { Type = "redact", Pattern = "email" },
            ],
        };
        Assert.True(spec.NeedsOcr);
        var anns = spec.Resolve(new SizeD(1000, 800), 2, screen);
        Assert.Equal([AnnotationKind.Step, AnnotationKind.Step, AnnotationKind.Arrow, AnnotationKind.Rectangle, AnnotationKind.Pixelate],
                     anns.Select(a => a.Kind));
        Assert.Equal(1, anns[0].Number);
        Assert.Equal(2, anns[1].Number);
        Assert.True(anns[0].Start.X < 300);
        Assert.Equal(new PointD(50, 60), anns[1].Start);
        Assert.Equal(new RectD(1, 2, 30, 40), anns[3].Rect);
        var end = anns[2].End;
        Assert.True(new RectD(492, 592, 106, 36).Inset(-1, -1).Contains(end));
        Assert.False(new RectD(500, 600, 90, 20).Inset(1, 1).Contains(end));
        Assert.NotNull(spec.Effects(2));
    }

    [Fact]
    public void SpecErrorsAreHelpful()
    {
        var missing = new AnnotationSpec { Annotations = [new() { Type = "step", At = new() { Text = "Delete" } }] };
        var e = Assert.Throws<SpecException>(() => missing.Resolve(new SizeD(100, 100), 1, screen));
        Assert.Contains("Delete", e.Message);
        Assert.Contains("Cancel Save", e.Message);
        var bad = new AnnotationSpec { Annotations = [new() { Type = "sparkle", At = new() { X = 1, Y = 1 } }] };
        Assert.Throws<SpecException>(() => bad.Resolve(new SizeD(10, 10), 1, []));
        Assert.Equal(new Rgba(124 / 255.0, 58 / 255.0, 237 / 255.0), AnnotationSpec.ParseColor("#7C3AED"));
    }

    [Fact]
    public void SpecDecodesFromJson()
    {
        var spec = RasterNestJson.Deserialize<AnnotationSpec>(
            """{"annotations":[{"type":"step","at":{"text":"Save"},"label":"Click"},{"type":"redact","pattern":"email"}]}""");
        Assert.Equal(2, spec.Annotations.Count);
        Assert.Equal("Click", spec.Annotations[0].Label);
    }

    [Fact]
    public void PngInfoReadsSizeAndDensity()
    {
        var info = PngInfo.Read(Convert.FromBase64String(ImageLayerTests.OnePixelB64));
        Assert.Equal(new PngInfo(1, 1, 2), info);
        Assert.Null(PngInfo.Read("nope"u8));
    }

    [Fact]
    public void GuideStemsAndMarkdown()
    {
        var guide = new Guide
        {
            Title = "T",
            Steps =
            [
                new() { Name = "Open Settings!", Caption = "Open it.", Capture = new() { Fullscreen = true } },
                new() { Capture = new() { File = "a.png" } },
            ],
        };
        Assert.Equal("01-open-settings", guide.Stem(0));
        Assert.Equal("02", guide.Stem(1));
        var md = guide.ToMarkdown(["img/01-open-settings.png", "img/02.png"]);
        Assert.StartsWith("# T\n", md);
        Assert.Contains("![Open it.](img/01-open-settings.png)", md);
        var roundTrip = Guide.Decoded(RasterNestJson.Serialize(Guide.Example));
        Assert.Equal(RasterNestJson.Serialize(Guide.Example), RasterNestJson.Serialize(roundTrip));
    }

    [Fact]
    public async Task McpServerProtocol()
    {
        var echo = new McpTool("echo", "Echo", new JsonObject { ["type"] = "object" }, args =>
        {
            var s = args.Str("text") ?? throw new SpecException("no text");
            return Task.FromResult<IReadOnlyList<McpContent>>([McpContent.FromText(s)]);
        });
        var server = new McpServer("t", "1", [echo]);

        async Task<JsonNode> Call(string s) => JsonNode.Parse((await server.HandleAsync(s))!)!;

        var init = await Call("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}""");
        Assert.Equal("2025-06-18", init["result"]!["protocolVersion"]!.GetValue<string>());
        var old = await Call("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}""");
        Assert.Equal(McpServer.SupportedVersions[0], old["result"]!["protocolVersion"]!.GetValue<string>());

        Assert.Null(await server.HandleAsync("""{"jsonrpc":"2.0","method":"notifications/initialized"}"""));

        var list = await Call("""{"jsonrpc":"2.0","id":"a","method":"tools/list"}""");
        Assert.Equal("a", list["id"]!.GetValue<string>());
        Assert.Equal("echo", list["result"]!["tools"]![0]!["name"]!.GetValue<string>());

        var ok = await Call("""{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}""");
        Assert.Equal("hi", ok["result"]!["content"]![0]!["text"]!.GetValue<string>());
        Assert.False(ok["result"]!["isError"]!.GetValue<bool>());

        var toolError = await Call("""{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{}}}""");
        Assert.True(toolError["result"]!["isError"]!.GetValue<bool>());

        var unknown = await Call("""{"jsonrpc":"2.0","id":4,"method":"nope"}""");
        Assert.Equal(-32601, unknown["error"]!["code"]!.GetValue<int>());

        var parse = await Call("{not json");
        Assert.Equal(-32700, parse["error"]!["code"]!.GetValue<int>());
    }
}

public class CombineAndStyleTests
{
    [Fact]
    public void SideBySideMatchesHeights()
    {
        var r = new CombineLayout { Arrangement = CombineArrangement.Horizontal, Gap = 10 }.Place([new(100, 50), new(40, 100)]);
        Assert.Equal(new RectD(0, 0, 200, 100), r.Frames[0]);
        Assert.Equal(new RectD(210, 0, 40, 100), r.Frames[1]);
        Assert.Equal(new SizeD(250, 100), r.Canvas);
    }

    [Fact]
    public void StackedWithoutMatchingCentersImages()
    {
        var r = new CombineLayout { Arrangement = CombineArrangement.Vertical, Gap = 0, Padding = 5, MatchSizes = false }
            .Place([new(100, 20), new(50, 30)]);
        Assert.Equal(new SizeD(110, 60), r.Canvas);
        Assert.Equal(new RectD(30, 25, 50, 30), r.Frames[1]);
    }

    [Fact]
    public void GridPicksNearSquareColumns()
    {
        var r = new CombineLayout { Arrangement = CombineArrangement.Grid, Gap = 2 }.Place(Enumerable.Repeat(new SizeD(10, 10), 5).ToList());
        Assert.Equal(new SizeD(3 * 10 + 2 * 2, 2 * 10 + 2), r.Canvas);
        Assert.Equal(new PointD(0, 12), r.Frames[3].Origin);
    }

    [Fact]
    public void SpecBlurAndDoubleArrow()
    {
        var spec = new AnnotationSpec
        {
            Annotations =
            [
                new() { Type = "blur", Around = new() { Rect = [0, 0, 10, 10] } },
                new() { Type = "redact", Around = new() { Rect = [0, 0, 5, 5] }, Style = "blur" },
                new() { Type = "arrow", From = new() { X = 0, Y = 0 }, To = new() { X = 50, Y = 50 }, Heads = 2 },
            ],
        };
        var anns = spec.Resolve(new SizeD(100, 100), 1, []);
        Assert.True(anns[0].Style.IsBlur);
        Assert.True(anns[1].Style.IsBlur);
        Assert.True(anns[2].Style.IsDoubleHeaded);
    }
}

public class ImageLayerTests
{
    // 1×1 PNG at 144 dpi, plus a 2×1 one at 72 dpi.
    internal const string OnePixelB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAABYlAAAWJQFJUiTwAAAADUlEQVQImWP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";
    private static readonly byte[] OnePixel = Convert.FromBase64String(OnePixelB64);
    private static readonly byte[] TwoByOne = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGP4z8DwnwGIGWAMAG3QB/k9OwOAAAAAAElFTkSuQmCC");

    [Fact]
    public void CornerDragKeepsAspectRatio()
    {
        Assert.Equal(2, PngInfo.Read(TwoByOne)?.Width);
        var layer = Annotation.ImageLayer(TwoByOne, new PointD(100, 100), new SizeD(100, 50), new AnnotationStyle());
        Assert.Equal(new RectD(50, 75, 100, 50), layer.Rect);
        layer.MoveHandle(1, new PointD(250, 80));
        Assert.Equal(50, layer.Rect.MinX);
        Assert.Equal(75, layer.Rect.MinY);
        Assert.Equal(2, layer.Rect.Width / layer.Rect.Height, 3);
        Assert.Equal(200, layer.Rect.Width, 3);
    }

    [Fact]
    public void DocumentVersionOnlyBumpsWithImageLayers()
    {
        var doc = new NestDocument(OnePixel, 1, []);
        Assert.Equal(1, NestDocument.Decoded(doc.Encoded()).FormatVersion);
        doc.Annotations.Add(Annotation.ImageLayer(OnePixel, PointD.Zero, new SizeD(4, 4), new AnnotationStyle()));
        var decoded = NestDocument.Decoded(doc.Encoded());
        Assert.Equal(2, decoded.FormatVersion);
        Assert.Equal(OnePixel, decoded.Annotations[0].ImagePng);
    }

    [Fact]
    public void SpecPlacesImageFittedToRect()
    {
        var path = Path.Combine(Path.GetTempPath(), $"rn-layer-{Guid.NewGuid()}.png");
        File.WriteAllBytes(path, TwoByOne);
        try
        {
            var spec = new AnnotationSpec { Annotations = [new() { Type = "image", File = path, Around = new() { Rect = [0, 0, 40, 40] } }] };
            var anns = spec.Resolve(new SizeD(100, 100), 1, []);
            Assert.Equal(AnnotationKind.Image, anns[0].Kind);
            Assert.Equal(new RectD(0, 10, 40, 20), anns[0].Rect);
        }
        finally { File.Delete(path); }
    }
}
