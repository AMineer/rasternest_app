using System.Text.Json;
using System.Text.Json.Nodes;
using RasterNest.Core;

namespace RasterNest.Core.Tests;

// Ports of Tests/RasterNestCoreTests (Swift). Keep both suites in step.

public class GeometryTests
{
    [Fact]
    public void RectNormalizes() =>
        Assert.Equal(new RectD(2, 5, 8, 15), Geometry.Rect(new PointD(10, 20), new PointD(2, 5)));

    [Fact]
    public void SegmentDistance()
    {
        PointD a = new(0, 0), b = new(10, 0);
        Assert.Equal(3, Geometry.DistanceToSegment(new PointD(5, 3), a, b), 4);
        Assert.Equal(5, Geometry.DistanceToSegment(new PointD(-4, 3), a, b), 4);
    }

    [Fact]
    public void ArrowHeadSitsOnTheShaft()
    {
        var head = Geometry.ArrowHeadFor(PointD.Zero, new PointD(100, 0), 4);
        Assert.Equal(new PointD(100, 0), head.Tip);
        Assert.True(head.Base.X < 100);
        Assert.Equal(0, head.Base.Y, 4);
        Assert.Equal(-head.Right.Y, head.Left.Y, 4);
    }

    [Fact]
    public void ArrowHeadNeverLongerThanArrow() =>
        Assert.True(Geometry.ArrowHeadFor(PointD.Zero, new PointD(5, 0), 10).Base.X >= -0.0001);

    [Fact]
    public void SnapAngle()
    {
        Assert.Equal(0, Geometry.SnapAngle(PointD.Zero, new PointD(100, 8)).Y, 4);
        var d = Geometry.SnapAngle(PointD.Zero, new PointD(50, 47));
        Assert.Equal(d.X, d.Y, 4);
    }

    [Fact]
    public void SnapSquare() =>
        Assert.Equal(new PointD(-20, 40), Geometry.SnapSquare(new PointD(10, 10), new PointD(0, 40)));
}

public class AnnotationTests
{
    [Fact]
    public void ArrowHitTest()
    {
        var a = new Annotation(AnnotationKind.Arrow, PointD.Zero, new PointD(100, 100));
        Assert.True(a.HitTest(new PointD(50, 52)));
        Assert.False(a.HitTest(new PointD(50, 80)));
    }

    [Fact]
    public void HollowRectangleHitsOnlyEdges()
    {
        var a = new Annotation(AnnotationKind.Rectangle, PointD.Zero, new PointD(100, 100));
        Assert.True(a.HitTest(new PointD(0, 50)));
        Assert.False(a.HitTest(new PointD(50, 50)));
        var filled = a.Clone();
        filled.Style.Filled = true;
        Assert.True(filled.HitTest(new PointD(50, 50)));
        Assert.False(a.Style.Filled); // clone doesn't share style
    }

    [Fact]
    public void EllipseHitTest()
    {
        var a = new Annotation(AnnotationKind.Ellipse, PointD.Zero, new PointD(200, 100));
        Assert.True(a.HitTest(new PointD(200, 50)));
        Assert.False(a.HitTest(new PointD(100, 50)));
        Assert.False(a.HitTest(new PointD(0, 0)));
    }

    [Fact]
    public void MoveHandleCorners()
    {
        var a = new Annotation(AnnotationKind.Rectangle, PointD.Zero, new PointD(10, 10));
        a.MoveHandle(2, new PointD(-5, 20));
        Assert.Equal(new RectD(-5, 0, 15, 20), a.Rect);
        a.MoveHandle(3, new PointD(30, -10));
        Assert.Equal(new RectD(-5, -10, 35, 30), a.Rect);
    }

    [Fact]
    public void TranslateMovesPenPoints()
    {
        var a = new Annotation(AnnotationKind.Pen, PointD.Zero, points: [PointD.Zero, new PointD(1, 1)]);
        a.Translate(5, -2);
        Assert.Equal([new PointD(5, -2), new PointD(6, -1)], a.Points);
    }

    [Fact]
    public void Degenerate()
    {
        Assert.True(new Annotation(AnnotationKind.Rectangle, PointD.Zero, new PointD(1, 2)).IsDegenerate);
        Assert.False(new Annotation(AnnotationKind.Rectangle, PointD.Zero, new PointD(10, 2)).IsDegenerate);
        Assert.False(new Annotation(AnnotationKind.Step, PointD.Zero).IsDegenerate);
    }

    [Fact]
    public void NextStepNumber()
    {
        Annotation[] list =
        [
            new(AnnotationKind.Step, PointD.Zero, number: 1),
            new(AnnotationKind.Arrow, PointD.Zero),
            new(AnnotationKind.Step, PointD.Zero, number: 4),
        ];
        Assert.Equal(5, Annotation.NextStepNumber(list));
        Assert.Equal(1, Annotation.NextStepNumber([]));
    }
}

public class DocumentTests
{
    internal static string Json(object o) => RasterNestJson.Serialize(o);

    [Fact]
    public void RoundTrip()
    {
        Annotation[] annotations =
        [
            new(AnnotationKind.Text, new PointD(3, 4), text: "Hello", style: new AnnotationStyle { Color = Rgba.Blue }),
            new(AnnotationKind.Step, new PointD(9, 9), number: 2),
        ];
        var doc = new NestDocument([1, 2, 3], 2, annotations);
        var decoded = NestDocument.Decoded(doc.Encoded());
        Assert.Equal(Json(annotations), Json(decoded.Annotations));
        Assert.Equal(new byte[] { 1, 2, 3 }, decoded.ImagePng);
        Assert.Equal(2, decoded.PixelScale);
    }

    [Fact]
    public void RejectsFutureVersions()
    {
        var doc = new NestDocument([], 1, []) { FormatVersion = 99 };
        var e = Assert.Throws<UnsupportedVersionException>(() => NestDocument.Decoded(doc.Encoded()));
        Assert.Equal(99, e.Version);
    }

    [Fact]
    public void WritesSwiftCompatibleJson()
    {
        var doc = new NestDocument([1], 2, [new Annotation(AnnotationKind.Arrow, new PointD(1, 2.5), new PointD(3, 4))],
                                   createdAt: new DateTimeOffset(2026, 11, 16, 19, 34, 46, 123, TimeSpan.Zero));
        var json = JsonNode.Parse(doc.Encoded())!.AsObject();
        Assert.Equal("2026-11-16T19:34:46Z", json["createdAt"]!.GetValue<string>());
        Assert.Equal("AQ==", json["imagePNG"]!.GetValue<string>());
        Assert.Equal(1, json["formatVersion"]!.GetValue<int>());
        var a = json["annotations"]![0]!.AsObject();
        Assert.Equal("[1,2.5]", a["start"]!.ToJsonString());
        Assert.Equal("arrow", a["kind"]!.GetValue<string>());
        Assert.Matches("^[0-9A-F-]{36}$", a["id"]!.GetValue<string>());
        Assert.Equal(0.94, a["style"]!["color"]!["r"]!.GetValue<double>());
        // Absent optionals aren't written (Swift omits nil), required fields always are.
        Assert.False(a["style"]!.AsObject().ContainsKey("blur"));
        Assert.False(a.ContainsKey("imagePNG"));
        Assert.True(a.ContainsKey("points"));
        Assert.False(json.ContainsKey("effects"));
    }

    [Fact]
    public void ReadsAFileWrittenByTheMacApp()
    {
        var doc = NestDocument.Load(Path.Combine(AppContext.BaseDirectory, "Fixtures", "mac-sample.rasternest"));
        Assert.Equal(2, doc.FormatVersion);
        Assert.Equal(2, doc.PixelScale);
        Assert.Equal(new PngInfo(600, 360, 2), PngInfo.Read(doc.ImagePng));
        Assert.Equal(
            [AnnotationKind.Step, AnnotationKind.Step, AnnotationKind.Arrow, AnnotationKind.Arrow, AnnotationKind.Rectangle,
             AnnotationKind.Ellipse, AnnotationKind.Highlight, AnnotationKind.Pixelate, AnnotationKind.Pixelate, AnnotationKind.Spotlight,
             AnnotationKind.Magnify, AnnotationKind.Text, AnnotationKind.Image],
            doc.Annotations.Select(a => a.Kind));
        Assert.Equal(2, doc.Annotations[1].Number);
        Assert.True(doc.Annotations[3].Style.IsDoubleHeaded);
        Assert.False(doc.Annotations[7].Style.IsBlur);
        Assert.True(doc.Annotations[8].Style.IsBlur);
        Assert.Equal(2.5, doc.Annotations[10].Style.Zoom);
        Assert.Equal("Callout text", doc.Annotations[11].Text);
        Assert.NotNull(doc.Annotations[12].ImagePng);
        Assert.Equal(FrameBackground.Gradient, doc.Effects!.Background);
        Assert.Equal(64, doc.Effects.Padding);

        // Writing it back and reading again keeps everything.
        var again = NestDocument.Decoded(doc.Encoded());
        Assert.Equal(Json(doc.Annotations), Json(again.Annotations));
        Assert.Equal(Json(doc.Effects), Json(again.Effects!));
    }
}

public class CanvasEffectsTests
{
    [Fact]
    public void EffectsRoundTripInDocument()
    {
        var effects = CanvasEffects.Documentation(2);
        var doc = new NestDocument([9], 2, [], effects);
        Assert.Equal(effects, NestDocument.Decoded(doc.Encoded()).Effects);
    }

    [Fact]
    public void DocumentsWithoutEffectsStillDecode()
    {
        var json = JsonNode.Parse(new NestDocument([], 1, []).Encoded())!.AsObject();
        json.Remove("effects");
        Assert.Null(NestDocument.Decoded(System.Text.Encoding.UTF8.GetBytes(json.ToJsonString())).Effects);
    }

    [Fact]
    public void OutputSizeAddsPaddingOnBothSides()
    {
        var e = new CanvasEffects { Padding = 30 };
        Assert.Equal(new SizeD(160, 110), e.OutputSize(new SizeD(100, 50)));
        Assert.True(CanvasEffects.None.IsEmpty);
        Assert.False(e.IsEmpty);
    }
}
