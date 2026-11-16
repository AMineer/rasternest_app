namespace RasterNest.Core;

/// <summary>A point in image pixels, origin top-left, y down. Serialized as <c>[x, y]</c> like Swift's CGPoint.</summary>
public readonly record struct PointD(double X, double Y)
{
    public static readonly PointD Zero = new(0, 0);
    public PointD Offset(double dx, double dy) => new(X + dx, Y + dy);
}

/// <summary>A size, serialized as <c>[width, height]</c>.</summary>
public readonly record struct SizeD(double Width, double Height)
{
    public static readonly SizeD Zero = new(0, 0);
}

/// <summary>
/// A rectangle with CoreGraphics semantics (so ported code behaves the same): negative sizes are
/// standardized, a failed intersection is <see cref="Null"/>, and containment is half-open.
/// </summary>
public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public static readonly RectD Zero = new(0, 0, 0, 0);
    public static readonly RectD Null = new(double.PositiveInfinity, double.PositiveInfinity, 0, 0);

    public RectD(PointD origin, SizeD size) : this(origin.X, origin.Y, size.Width, size.Height) { }

    public bool IsNull => double.IsPositiveInfinity(X) || double.IsPositiveInfinity(Y);
    public bool IsEmpty => IsNull || Width == 0 || Height == 0;

    public RectD Standardized => new(Math.Min(X, X + Width), Math.Min(Y, Y + Height), Math.Abs(Width), Math.Abs(Height));

    public double MinX => Standardized.X;
    public double MinY => Standardized.Y;
    public double MaxX => Standardized.X + Standardized.Width;
    public double MaxY => Standardized.Y + Standardized.Height;
    public double MidX => (MinX + MaxX) / 2;
    public double MidY => (MinY + MaxY) / 2;
    public PointD Origin => new(X, Y);
    public SizeD Size => new(Width, Height);
    public PointD Center => new(MidX, MidY);

    public RectD Inset(double dx, double dy)
    {
        if (IsNull) return Null;
        var s = Standardized;
        var w = s.Width - dx * 2;
        var h = s.Height - dy * 2;
        if (w < 0 || h < 0) return Null;
        return new RectD(s.X + dx, s.Y + dy, w, h);
    }

    public RectD Intersect(RectD other)
    {
        if (IsNull || other.IsNull) return Null;
        var x1 = Math.Max(MinX, other.MinX);
        var y1 = Math.Max(MinY, other.MinY);
        var x2 = Math.Min(MaxX, other.MaxX);
        var y2 = Math.Min(MaxY, other.MaxY);
        if (x2 < x1 || y2 < y1) return Null;
        return new RectD(x1, y1, x2 - x1, y2 - y1);
    }

    public RectD Union(RectD other)
    {
        if (IsNull) return other;
        if (other.IsNull) return this;
        var x1 = Math.Min(MinX, other.MinX);
        var y1 = Math.Min(MinY, other.MinY);
        return new RectD(x1, y1, Math.Max(MaxX, other.MaxX) - x1, Math.Max(MaxY, other.MaxY) - y1);
    }

    public bool Contains(PointD p) => !IsNull && p.X >= MinX && p.X < MaxX && p.Y >= MinY && p.Y < MaxY;

    public bool Contains(RectD r) => !IsNull && !r.IsNull && r.MinX >= MinX && r.MaxX <= MaxX && r.MinY >= MinY && r.MaxY <= MaxY;

    /// <summary>Smallest rectangle with whole-number edges that contains this one.</summary>
    public RectD Integral
    {
        get
        {
            if (IsNull) return Null;
            var x = Math.Floor(MinX);
            var y = Math.Floor(MinY);
            return new RectD(x, y, Math.Ceiling(MaxX) - x, Math.Ceiling(MaxY) - y);
        }
    }

    public RectD Offset(double dx, double dy) => new(X + dx, Y + dy, Width, Height);

    // The record's generated ToString would print Standardized (a RectD) and recurse forever.
    public override string ToString() => IsNull ? "RectD.Null" : $"RectD({X}, {Y}, {Width}, {Height})";
}
