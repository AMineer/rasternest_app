namespace RasterNest.Core;

public readonly record struct ArrowHead(PointD Tip, PointD Base, PointD Left, PointD Right);

/// <summary>Pure geometry helpers shared by the renderer, hit testing and tests.</summary>
public static class Geometry
{
    public static RectD Rect(PointD a, PointD b) =>
        new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    public static double Distance(PointD a, PointD b)
    {
        double dx = a.X - b.X, dy = a.Y - b.Y;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    public static PointD Midpoint(PointD a, PointD b) => new((a.X + b.X) / 2, (a.Y + b.Y) / 2);

    /// <summary>Shortest distance from <paramref name="p"/> to the segment a–b.</summary>
    public static double DistanceToSegment(PointD p, PointD a, PointD b)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y;
        var lengthSquared = dx * dx + dy * dy;
        if (lengthSquared <= 0) return Distance(p, a);
        var t = ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / lengthSquared;
        t = Math.Clamp(t, 0, 1);
        return Distance(p, new PointD(a.X + t * dx, a.Y + t * dy));
    }

    public static RectD BoundingBox(IReadOnlyList<PointD> points)
    {
        if (points.Count == 0) return RectD.Zero;
        double minX = points[0].X, minY = points[0].Y, maxX = minX, maxY = minY;
        for (var i = 1; i < points.Count; i++)
        {
            var p = points[i];
            minX = Math.Min(minX, p.X); minY = Math.Min(minY, p.Y);
            maxX = Math.Max(maxX, p.X); maxY = Math.Max(maxY, p.Y);
        }
        return new RectD(minX, minY, maxX - minX, maxY - minY);
    }

    /// <summary>Arrow head triangle for an arrow from start to end. The shaft should be drawn to <c>Base</c>.</summary>
    public static ArrowHead ArrowHeadFor(PointD start, PointD end, double lineWidth)
    {
        double dx = end.X - start.X, dy = end.Y - start.Y;
        var length = Math.Max(Math.Sqrt(dx * dx + dy * dy), 0.0001);
        double ux = dx / length, uy = dy / length;
        var headLength = Math.Min(length, Math.Max(lineWidth * 3.2, 10));
        var halfWidth = Math.Max(headLength * 0.55, lineWidth);
        var b = new PointD(end.X - ux * headLength, end.Y - uy * headLength);
        var left = new PointD(b.X - uy * halfWidth, b.Y + ux * halfWidth);
        var right = new PointD(b.X + uy * halfWidth, b.Y - ux * halfWidth);
        return new ArrowHead(end, b, left, right);
    }

    /// <summary>Snaps the segment start→end to the nearest 45° angle, preserving length.</summary>
    public static PointD SnapAngle(PointD start, PointD end)
    {
        double dx = end.X - start.X, dy = end.Y - start.Y;
        var length = Math.Sqrt(dx * dx + dy * dy);
        var step = Math.PI / 4;
        var angle = Math.Round(Math.Atan2(dy, dx) / step, MidpointRounding.AwayFromZero) * step;
        return new PointD(start.X + Math.Cos(angle) * length, start.Y + Math.Sin(angle) * length);
    }

    /// <summary>Constrains the rectangle spanned by start→end to a square.</summary>
    public static PointD SnapSquare(PointD start, PointD end)
    {
        double dx = end.X - start.X, dy = end.Y - start.Y;
        var side = Math.Max(Math.Abs(dx), Math.Abs(dy));
        return new PointD(start.X + (dx < 0 ? -side : side), start.Y + (dy < 0 ? -side : side));
    }
}
