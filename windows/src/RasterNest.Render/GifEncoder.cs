using SkiaSharp;

namespace RasterNest.Render;

/// <summary>
/// Writes looping animated GIFs. Tuned for screen recordings: each frame gets its own 256-colour palette
/// (screens are mostly flat colour, so no dithering), and pixels that didn't change since the previous frame
/// are written as transparent so static areas cost almost nothing.
/// </summary>
public sealed class GifEncoder : IDisposable
{
    private readonly Stream stream;
    private readonly int width, height;
    private uint[]? previous;
    private bool finished;

    public int FrameCount { get; private set; }

    public GifEncoder(Stream output, int width, int height)
    {
        stream = output;
        this.width = width;
        this.height = height;
        // Header, logical screen (no global table), NETSCAPE2.0 loop forever.
        Write("GIF89a"u8);
        WriteU16(width); WriteU16(height);
        stream.WriteByte(0x00); stream.WriteByte(0); stream.WriteByte(0);
        Write([0x21, 0xFF, 0x0B]);
        Write("NETSCAPE2.0"u8);
        Write([0x03, 0x01, 0x00, 0x00, 0x00]);
    }

    /// <summary>Adds a frame shown for delayCs hundredths of a second. The bitmap must be width × height.</summary>
    public void AddFrame(SKBitmap frame, int delayCs)
    {
        if (frame.Width != width || frame.Height != height) throw new ArgumentException("Every GIF frame must be the same size.");
        var pixels = ReadBgra(frame);

        // Only the rectangle that changed is written; everything else stays from the previous frame.
        int x0 = 0, y0 = 0, x1 = width - 1, y1 = height - 1;
        if (previous != null && !DirtyRect(pixels, previous, out x0, out y0, out x1, out y1))
        {
            // Nothing changed: stretch the previous frame instead of writing a new one.
            x0 = y0 = 0; x1 = y1 = 0;
        }
        int w = x1 - x0 + 1, h = y1 - y0 + 1;

        // Palette from the changed area; index 255 is reserved for "unchanged" (transparent) after the first frame.
        var useTransparency = previous != null;
        var maxColors = useTransparency ? 255 : 256;
        var (palette, lookup) = BuildPalette(pixels, x0, y0, w, h, maxColors);
        var indices = new byte[w * h];
        var cache = new Dictionary<uint, byte>();
        for (var y = 0; y < h; y++)
        {
            var row = (y0 + y) * width;
            for (var x = 0; x < w; x++)
            {
                var i = row + x0 + x;
                var c = pixels[i];
                if (useTransparency && previous![i] == c) { indices[y * w + x] = 255; continue; }
                if (!cache.TryGetValue(c, out var idx))
                {
                    idx = lookup.TryGetValue(c | ExactFlag, out var hit) || lookup.TryGetValue(Quantize(c), out hit) ? hit : Nearest(palette, c);
                    cache[c] = idx;
                }
                indices[y * w + x] = idx;
            }
        }

        // Graphic control extension: delay, disposal "leave in place", optional transparency.
        Write([0x21, 0xF9, 0x04, (byte)((1 << 2) | (useTransparency ? 1 : 0))]);
        WriteU16(Math.Clamp(delayCs, 2, 65535));
        stream.WriteByte(useTransparency ? (byte)255 : (byte)0);
        stream.WriteByte(0);

        // Image descriptor with a local 256-entry colour table.
        stream.WriteByte(0x2C);
        WriteU16(x0); WriteU16(y0); WriteU16(w); WriteU16(h);
        stream.WriteByte(0x87); // local table, 2^(7+1) = 256 entries
        for (var i = 0; i < 256; i++)
        {
            var c = i < palette.Count ? palette[i] : 0u;
            stream.WriteByte((byte)(c >> 16)); stream.WriteByte((byte)(c >> 8)); stream.WriteByte((byte)c);
        }
        Lzw(indices, 8);

        previous = pixels;
        FrameCount++;
    }

    public void Finish()
    {
        if (finished) return;
        finished = true;
        stream.WriteByte(0x3B);
        stream.Flush();
    }

    public void Dispose() => Finish();

    // MARK: pixels

    private static uint[] ReadBgra(SKBitmap frame)
    {
        using var bgra = frame.ColorType == SKColorType.Bgra8888 ? null : frame.Copy(SKColorType.Bgra8888);
        var src = (bgra ?? frame).GetPixelSpan();
        var output = new uint[frame.Width * frame.Height];
        var rowBytes = (bgra ?? frame).RowBytes;
        for (var y = 0; y < frame.Height; y++)
        {
            var row = src.Slice(y * rowBytes, frame.Width * 4);
            for (var x = 0; x < frame.Width; x++)
                output[y * frame.Width + x] = (uint)(row[x * 4 + 2] << 16 | row[x * 4 + 1] << 8 | row[x * 4]); // 0xRRGGBB
        }
        return output;
    }

    private bool DirtyRect(uint[] a, uint[] b, out int x0, out int y0, out int x1, out int y1)
    {
        x0 = width; y0 = height; x1 = -1; y1 = -1;
        for (var y = 0; y < height; y++)
        {
            var row = y * width;
            for (var x = 0; x < width; x++)
            {
                if (a[row + x] == b[row + x]) continue;
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                y1 = y;
            }
        }
        return x1 >= 0;
    }

    /// <summary>
    /// Up to maxColors colours: every exact colour when there are few (typical for UI), otherwise the most common
    /// colours on a 5-bit-per-channel grid, averaged within each cell. Lookup maps exact colours (few-colour case)
    /// or grid cells (many-colour case) to palette indices.
    /// </summary>
    private (List<uint> Palette, Dictionary<uint, byte> Lookup) BuildPalette(uint[] px, int x0, int y0, int w, int h, int maxColors)
    {
        var exact = new HashSet<uint>();
        var tooMany = false;
        var counts = new Dictionary<uint, (long R, long G, long B, int N)>();
        var step = w * h > 600_000 ? 2 : 1;
        for (var y = 0; y < h; y += step)
        {
            var row = (y0 + y) * width + x0;
            for (var x = 0; x < w; x += step)
            {
                var c = px[row + x];
                if (!tooMany && exact.Add(c) && exact.Count > maxColors) tooMany = true;
                var key = Quantize(c);
                var e = counts.GetValueOrDefault(key);
                counts[key] = (e.R + (c >> 16 & 0xFF), e.G + (c >> 8 & 0xFF), e.B + (c & 0xFF), e.N + 1);
            }
        }
        var lookup = new Dictionary<uint, byte>();
        var palette = new List<uint>();
        if (!tooMany && step == 1)
        {
            foreach (var c in exact) { lookup[c | ExactFlag] = (byte)palette.Count; palette.Add(c); }
            return (palette, lookup);
        }
        // Median cut over the 5-bit grid cells, weighted by how many pixels fall in each.
        var cells = counts.Select(kv => (Key: kv.Key, R: (int)(kv.Value.R / kv.Value.N), G: (int)(kv.Value.G / kv.Value.N),
                                        B: (int)(kv.Value.B / kv.Value.N), N: kv.Value.N)).ToList();
        static (long Score, int Channel) Stats(List<(uint Key, int R, int G, int B, int N)> b)
        {
            if (b.Count < 2) return (0, 0);
            int rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0; long n = 0;
            foreach (var c in b)
            {
                rMin = Math.Min(rMin, c.R); rMax = Math.Max(rMax, c.R); gMin = Math.Min(gMin, c.G); gMax = Math.Max(gMax, c.G);
                bMin = Math.Min(bMin, c.B); bMax = Math.Max(bMax, c.B); n += c.N;
            }
            int rr = rMax - rMin, gr = gMax - gMin, br = bMax - bMin, range = Math.Max(rr, Math.Max(gr, br));
            return ((long)range * n, range == rr ? 0 : range == gr ? 1 : 2);
        }
        var boxes = new List<(List<(uint Key, int R, int G, int B, int N)> Cells, long Score, int Channel)>();
        { var st = Stats(cells); boxes.Add((cells, st.Score, st.Channel)); }
        while (boxes.Count < maxColors)
        {
            // Split the box with the widest colour range (weighted by population) at its weighted median.
            var bestIndex = -1; long bestScore = 0;
            for (var i = 0; i < boxes.Count; i++) if (boxes[i].Score > bestScore) { bestScore = boxes[i].Score; bestIndex = i; }
            if (bestIndex < 0) break;
            var (box, _, channel) = boxes[bestIndex];
            box.Sort((a, b) => channel switch { 0 => a.R.CompareTo(b.R), 1 => a.G.CompareTo(b.G), _ => a.B.CompareTo(b.B) });
            long total = box.Sum(c => (long)c.N), acc = 0;
            var cut = 1;
            for (var i = 0; i < box.Count - 1; i++) { acc += box[i].N; cut = i + 1; if (acc * 2 >= total) break; }
            var left = box.GetRange(0, cut);
            var right = box.GetRange(cut, box.Count - cut);
            var ls = Stats(left); var rs = Stats(right);
            boxes[bestIndex] = (left, ls.Score, ls.Channel);
            boxes.Add((right, rs.Score, rs.Channel));
        }
        foreach (var (b, _, _) in boxes)
        {
            long n = b.Sum(c => (long)c.N);
            var color = (uint)(b.Sum(c => (long)c.R * c.N) / n) << 16 | (uint)(b.Sum(c => (long)c.G * c.N) / n) << 8 | (uint)(b.Sum(c => (long)c.B * c.N) / n);
            foreach (var c in b) lookup[c.Key] = (byte)palette.Count;
            palette.Add(color);
        }
        return (palette, lookup);
    }

    private const uint ExactFlag = 0x8000_0000;

    private static uint Quantize(uint c) => (c >> 19 & 0x1F) << 10 | (c >> 11 & 0x1F) << 5 | (c >> 3 & 0x1F);

    private static byte Nearest(List<uint> palette, uint c)
    {
        int r = (int)(c >> 16 & 0xFF), g = (int)(c >> 8 & 0xFF), b = (int)(c & 0xFF);
        var best = 0; var bestD = int.MaxValue;
        for (var i = 0; i < palette.Count; i++)
        {
            var p = palette[i];
            int dr = r - (int)(p >> 16 & 0xFF), dg = g - (int)(p >> 8 & 0xFF), db = b - (int)(p & 0xFF);
            var d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
            if (d < bestD) { bestD = d; best = i; if (d == 0) break; }
        }
        return (byte)best;
    }

    // MARK: LZW

    private void Lzw(byte[] indices, int minCodeSize)
    {
        stream.WriteByte((byte)minCodeSize);
        var block = new byte[255];
        var blockLen = 0;
        var bitBuffer = 0; var bitCount = 0;

        void Emit(int code, int size)
        {
            bitBuffer |= code << bitCount;
            bitCount += size;
            while (bitCount >= 8)
            {
                block[blockLen++] = (byte)bitBuffer;
                bitBuffer >>= 8; bitCount -= 8;
                if (blockLen == 255) { stream.WriteByte(255); stream.Write(block, 0, 255); blockLen = 0; }
            }
        }

        int clear = 1 << minCodeSize, end = clear + 1;
        var codeSize = minCodeSize + 1;
        var next = end + 1;
        var table = new Dictionary<int, int>(4096);
        Emit(clear, codeSize);
        if (indices.Length == 0) { Emit(end, codeSize); goto flush; }
        var prefix = (int)indices[0];
        for (var i = 1; i < indices.Length; i++)
        {
            var k = indices[i];
            var key = prefix << 8 | k;
            if (table.TryGetValue(key, out var code)) { prefix = code; continue; }
            Emit(prefix, codeSize);
            if (next < 4096)
            {
                table[key] = next++;
                if (next > 1 << codeSize && codeSize < 12) codeSize++;
            }
            else
            {
                Emit(clear, codeSize);
                table.Clear();
                codeSize = minCodeSize + 1;
                next = end + 1;
            }
            prefix = k;
        }
        Emit(prefix, codeSize);
        // The decoder adds one more entry after reading that code; match its code size for the end code.
        if (next == 1 << codeSize && codeSize < 12) codeSize++;
        Emit(end, codeSize);
        flush:
        if (bitCount > 0) Emit(0, 8 - bitCount);
        if (blockLen > 0) { stream.WriteByte((byte)blockLen); stream.Write(block, 0, blockLen); }
        stream.WriteByte(0);
    }

    private void Write(ReadOnlySpan<byte> bytes) => stream.Write(bytes);
    private void WriteU16(int v) { stream.WriteByte((byte)v); stream.WriteByte((byte)(v >> 8)); }
}
