namespace RasterNest.Core;

/// <summary>Reads a PNG's pixel size and density from its header, without an image library.</summary>
public readonly record struct PngInfo(int Width, int Height, double Scale)
{
    private static readonly byte[] Signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    /// <summary>Pixels per point come from the pHYs chunk (144 dpi → 2); 1 when absent.</summary>
    public static PngInfo? Read(ReadOnlySpan<byte> data)
    {
        var b = data[..Math.Min(data.Length, 4096)];
        if (b.Length < 33 || !b[..8].SequenceEqual(Signature)) return null;
        int U32(ReadOnlySpan<byte> s, int i) => s[i] << 24 | s[i + 1] << 16 | s[i + 2] << 8 | s[i + 3];
        if (b[12] != 'I' || b[13] != 'H' || b[14] != 'D' || b[15] != 'R') return null;
        var width = U32(b, 16);
        var height = U32(b, 20);
        double scale = 1;
        // Walk the chunks that fit in the prefix looking for pHYs (pixels per metre).
        var i = 8;
        while (i + 12 <= b.Length)
        {
            var length = U32(b, i);
            var type = System.Text.Encoding.ASCII.GetString(b.Slice(i + 4, 4));
            if (type == "pHYs" && i + 17 <= b.Length && b[i + 16] == 1)
            {
                var dpi = U32(b, i + 8) * 0.0254;
                scale = Math.Max(1, Math.Round(dpi / 72 * 2, MidpointRounding.AwayFromZero) / 2);
                break;
            }
            if (type is "IDAT" or "IEND" || length < 0) break;
            i += 12 + length;
        }
        return new PngInfo(width, height, scale);
    }
}
