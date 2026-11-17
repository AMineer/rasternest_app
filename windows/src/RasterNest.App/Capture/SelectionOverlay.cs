using System.Runtime.InteropServices;
using RasterNest.App.Shell;
using RasterNest.Core;
using RasterNest.Windows;
using SkiaSharp;
using static RasterNest.App.Shell.Win32;

namespace RasterNest.App.Capture;

/// <summary>
/// The capture overlay: a frozen picture of every display. Drag for an area, click a highlighted window,
/// Space for the display under the pointer, C to copy the colour under the pointer, Esc to cancel.
/// Drawn with GDI over one window that spans the virtual desktop (in physical pixels).
/// </summary>
internal sealed class SelectionOverlay : IDisposable
{
    public abstract record Result
    {
        /// <summary>An area, in virtual-desktop pixels.</summary>
        public sealed record Region(RectI Rect) : Result;
        public sealed record Window(WindowDescriptor Info, RectI Visible) : Result;
        public sealed record Display(DisplayDescriptor Info) : Result;
        public sealed record Cancelled : Result;
    }

    public readonly record struct RectI(int X, int Y, int W, int H)
    {
        public int Right => X + W;
        public int Bottom => Y + H;
        public bool Contains(int px, int py) => px >= X && px < Right && py >= Y && py < Bottom;
        public RectI Intersect(RectI o)
        {
            int l = Math.Max(X, o.X), t = Math.Max(Y, o.Y), r = Math.Min(Right, o.Right), b = Math.Min(Bottom, o.Bottom);
            return r > l && b > t ? new RectI(l, t, r - l, b - t) : new RectI(0, 0, 0, 0);
        }
    }

    private static readonly WndProc Proc = StaticWndProc;
    private static SelectionOverlay? active;
    private static bool classRegistered;

    /// <summary>The frozen screen (virtual desktop, physical pixels).</summary>
    public SKBitmap Frozen { get; }
    public RectI Virtual { get; }
    private readonly List<WindowDescriptor> windows;
    private readonly List<DisplayDescriptor> displays;
    private readonly string hint;
    private readonly Action<Result> completion;

    private IntPtr hwnd, backDc, backBmp, backBits, brightDc, brightBmp, dimDc, dimBmp;
    private int mouseX, mouseY;
    private (int X, int Y)? dragStart;
    private bool dragging;
    private RectI? hover;
    private WindowDescriptor? hoverWindow;
    private bool finished;
    private string? toast;

    public SelectionOverlay(string hint, Action<Result> completion)
    {
        this.hint = hint;
        this.completion = completion;
        Virtual = new RectI(GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
                            GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
        displays = ScreenCapture.Displays();
        windows = ScreenCapture.Windows();
        var shot = ScreenCapture.CaptureRect(new RectD(Virtual.X, Virtual.Y, Virtual.W, Virtual.H), AppSettings.Shared.CaptureCursor);
        Frozen = shot.Bitmap;
    }

    public void Show()
    {
        active = this;
        var instance = GetModuleHandle(null);
        if (!classRegistered)
        {
            var wc = new WNDCLASSEX
            {
                cbSize = Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = Proc, hInstance = instance,
                hCursor = LoadCursor(IntPtr.Zero, IDC_CROSS), lpszClassName = "RasterNestOverlay",
            };
            RegisterClassEx(ref wc);
            classRegistered = true;
        }
        PrepareSurfaces();
        GetCursorPos(out var p);
        mouseX = p.X; mouseY = p.Y;
        UpdateHover();
        hwnd = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, "RasterNestOverlay", "RasterNest capture", WS_POPUP,
                              Virtual.X, Virtual.Y, Virtual.W, Virtual.H, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
    }

    // MARK: drawing

    private void PrepareSurfaces()
    {
        var screen = GetDC(IntPtr.Zero);
        (brightDc, brightBmp, var brightBits) = MakeDib(screen, Virtual.W, Virtual.H);
        (dimDc, dimBmp, var dimBits) = MakeDib(screen, Virtual.W, Virtual.H);
        (backDc, backBmp, backBits) = MakeDib(screen, Virtual.W, Virtual.H);
        ReleaseDC(IntPtr.Zero, screen);

        var bytes = Virtual.W * Virtual.H * 4;
        using var bgra = Frozen.ColorType == SKColorType.Bgra8888 ? null : Frozen.Copy(SKColorType.Bgra8888);
        var src = (bgra ?? Frozen).GetPixels();
        unsafe { Buffer.MemoryCopy((void*)src, (void*)brightBits, bytes, bytes); }
        // The dimmed copy: 45% black over the picture.
        using var dim = new SKBitmap(new SKImageInfo(Virtual.W, Virtual.H, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(dim))
        {
            canvas.DrawBitmap(bgra ?? Frozen, 0, 0);
            using var paint = new SKPaint { Color = new SKColor(0, 0, 0, 115) };
            canvas.DrawRect(0, 0, Virtual.W, Virtual.H, paint);
        }
        unsafe { Buffer.MemoryCopy((void*)dim.GetPixels(), (void*)dimBits, bytes, bytes); }
    }

    private static (IntPtr Dc, IntPtr Bmp, IntPtr Bits) MakeDib(IntPtr screen, int w, int h)
    {
        var dc = CreateCompatibleDC(screen);
        var header = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        var bmp = CreateDIBSection(dc, ref header, 0, out var bits, IntPtr.Zero, 0);
        SelectObject(dc, bmp);
        return (dc, bmp, bits);
    }

    private RectI? Selection
    {
        get
        {
            if (dragging && dragStart is { } s)
            {
                int x0 = Math.Min(s.X, mouseX), y0 = Math.Min(s.Y, mouseY);
                return new RectI(x0 - Virtual.X, y0 - Virtual.Y, Math.Abs(mouseX - s.X), Math.Abs(mouseY - s.Y));
            }
            return hover;
        }
    }

    private void Paint(IntPtr hdc)
    {
        BitBlt(backDc, 0, 0, Virtual.W, Virtual.H, dimDc, 0, 0, SRCCOPY);
        if (Selection is { W: > 0, H: > 0 } sel)
        {
            BitBlt(backDc, sel.X, sel.Y, sel.W, sel.H, brightDc, sel.X, sel.Y, SRCCOPY);
            var pen = CreatePen(PS_SOLID, 2, 0x00E9A50E); // sky #0EA5E9 as 0x00BBGGRR
            var oldPen = SelectObject(backDc, pen);
            var oldBrush = SelectObject(backDc, GetStockObject(NULL_BRUSH));
            Rectangle(backDc, sel.X - 1, sel.Y - 1, sel.Right + 1, sel.Bottom + 1);
            SelectObject(backDc, oldPen);
            SelectObject(backDc, oldBrush);
            DeleteObject(pen);
            var label = dragging || hoverWindow == null ? $"{sel.W} × {sel.H}" : $"{hoverWindow.Owner}  {sel.W} × {sel.H}";
            Blit(Label(label, 13), sel.X, sel.Y - 30 >= 0 ? sel.Y - 30 : sel.Bottom + 6);
        }
        DrawHint();
        DrawLoupe();
        BitBlt(hdc, 0, 0, Virtual.W, Virtual.H, backDc, 0, 0, SRCCOPY);
    }

    private DisplayDescriptor DisplayUnderMouse() =>
        displays.FirstOrDefault(d => mouseX >= d.X && mouseX < d.X + d.Width && mouseY >= d.Y && mouseY < d.Y + d.Height) ?? displays[0];

    private void DrawHint()
    {
        var d = DisplayUnderMouse();
        using var bmp = Label(toast ?? hint, 14, pill: true);
        var x = (int)(d.X - Virtual.X + (d.Width - bmp.Width) / 2);
        var y = (int)(d.Y - Virtual.Y + 24 * d.Scale);
        Blit(bmp, x, y);
    }

    /// <summary>A magnified view of the pixels under the pointer with their colour.</summary>
    private void DrawLoupe()
    {
        const int cells = 15, cell = 9;
        var size = cells * cell;
        using var bmp = new SKBitmap(new SKImageInfo(size + 4, size + 30, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var c = new SKCanvas(bmp))
        {
            c.Clear(SKColors.Transparent);
            using var bg = new SKPaint { Color = new SKColor(20, 20, 24, 235), IsAntialias = true };
            c.DrawRoundRect(0, 0, size + 4, size + 30, 8, 8, bg);
            int fx = mouseX - Virtual.X, fy = mouseY - Virtual.Y;
            using var px = new SKPaint();
            for (var j = 0; j < cells; j++)
                for (var i = 0; i < cells; i++)
                {
                    int sx = fx + i - cells / 2, sy = fy + j - cells / 2;
                    px.Color = sx >= 0 && sy >= 0 && sx < Frozen.Width && sy < Frozen.Height ? Frozen.GetPixel(sx, sy) : SKColors.Black;
                    c.DrawRect(2 + i * cell, 2 + j * cell, cell, cell, px);
                }
            using var ring = new SKPaint { Color = SKColors.White, IsStroke = true, StrokeWidth = 1.5f };
            c.DrawRect(2 + cells / 2 * cell, 2 + cells / 2 * cell, cell, cell, ring);
            var color = fx >= 0 && fy >= 0 && fx < Frozen.Width && fy < Frozen.Height ? Frozen.GetPixel(fx, fy) : SKColors.Black;
            var hex = $"#{color.Red:X2}{color.Green:X2}{color.Blue:X2}";
            using var swatch = new SKPaint { Color = color };
            c.DrawRect(8, size + 10, 14, 14, swatch);
            using var font = new SKFont(SKTypeface.FromFamilyName("Segoe UI", SKFontStyle.Bold), 12);
            using var text = new SKPaint { Color = SKColors.White, IsAntialias = true };
            c.DrawText($"{hex}   C copies", 28, size + 22, SKTextAlign.Left, font, text);
        }
        // Beside the pointer, flipped when near an edge.
        var lx = mouseX - Virtual.X + 24;
        var ly = mouseY - Virtual.Y + 24;
        if (lx + bmp.Width > Virtual.W) lx = mouseX - Virtual.X - 24 - bmp.Width;
        if (ly + bmp.Height > Virtual.H) ly = mouseY - Virtual.Y - 24 - bmp.Height;
        Blit(bmp, lx, ly, blend: true);
    }

    private static SKBitmap Label(string text, float size, bool pill = false)
    {
        using var font = new SKFont(SKTypeface.FromFamilyName("Segoe UI", SKFontStyle.Bold), size);
        var w = (int)Math.Ceiling(font.MeasureText(text)) + 20;
        var h = (int)Math.Ceiling(size * 1.9f);
        var bmp = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        using var bg = new SKPaint { Color = pill ? new SKColor(20, 20, 24, 225) : new SKColor(14, 165, 233), IsAntialias = true };
        c.DrawRoundRect(0, 0, w, h, pill ? h / 2f : 6, pill ? h / 2f : 6, bg);
        using var fg = new SKPaint { Color = SKColors.White, IsAntialias = true };
        c.DrawText(text, 10, h / 2f + size * 0.36f, SKTextAlign.Left, font, fg);
        return bmp;
    }

    /// <summary>Draws a small Skia bitmap into the back buffer (alpha-blended in software).</summary>
    private unsafe void Blit(SKBitmap bmp, int x, int y, bool blend = true)
    {
        var dst = (byte*)backBits;
        var src = (byte*)bmp.GetPixels();
        for (var j = 0; j < bmp.Height; j++)
        {
            var ty = y + j;
            if (ty < 0 || ty >= Virtual.H) continue;
            for (var i = 0; i < bmp.Width; i++)
            {
                var tx = x + i;
                if (tx < 0 || tx >= Virtual.W) continue;
                var s = src + (j * bmp.RowBytes) + i * 4;
                var d = dst + ((long)ty * Virtual.W + tx) * 4;
                int a = s[3];
                if (a == 0) continue;
                // Premultiplied source over opaque destination.
                d[0] = (byte)(s[0] + d[0] * (255 - a) / 255);
                d[1] = (byte)(s[1] + d[1] * (255 - a) / 255);
                d[2] = (byte)(s[2] + d[2] * (255 - a) / 255);
            }
        }
        bmp.Dispose();
    }

    // MARK: input

    private void UpdateHover()
    {
        hoverWindow = windows.FirstOrDefault(w => mouseX >= w.X && mouseX < w.X + w.Width && mouseY >= w.Y && mouseY < w.Y + w.Height
                                                  && w.Width >= 40 && w.Height >= 30);
        if (hoverWindow is { } w)
        {
            var r = new RectI((int)w.X - Virtual.X, (int)w.Y - Virtual.Y, (int)w.Width, (int)w.Height).Intersect(new RectI(0, 0, Virtual.W, Virtual.H));
            hover = r.W > 0 ? r : null;
        }
        else hover = null;
    }

    private void Finish(Result result)
    {
        if (finished) return;
        finished = true;
        ReleaseCapture();
        DestroyWindow(hwnd);
        completion(result);
    }

    private IntPtr Handle(uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            case WM_ERASEBKGND:
                return 1;
            case WM_PAINT:
            {
                var hdc = BeginPaint(hwnd, out var ps);
                Paint(hdc);
                EndPaint(hwnd, ref ps);
                return IntPtr.Zero;
            }
            case WM_MOUSEMOVE:
            {
                mouseX = Virtual.X + LoWord(lParam);
                mouseY = Virtual.Y + HiWord(lParam);
                toast = null;
                if (dragStart is { } s && !dragging && (Math.Abs(mouseX - s.X) > 4 || Math.Abs(mouseY - s.Y) > 4)) dragging = true;
                if (!dragging) UpdateHover();
                InvalidateRect(hwnd, IntPtr.Zero, false);
                return IntPtr.Zero;
            }
            case WM_LBUTTONDOWN:
                dragStart = (Virtual.X + LoWord(lParam), Virtual.Y + HiWord(lParam));
                SetCapture(hwnd);
                return IntPtr.Zero;
            case WM_LBUTTONUP:
            {
                // A release without a press here (e.g. the click that chose the tray menu item) means nothing.
                if (dragStart == null) return IntPtr.Zero;
                ReleaseCapture();
                if (dragging && Selection is { } sel)
                {
                    if (sel.W >= 4 && sel.H >= 4) Finish(new Result.Region(sel with { X = sel.X + Virtual.X, Y = sel.Y + Virtual.Y }));
                    else { dragging = false; dragStart = null; }
                    return IntPtr.Zero;
                }
                dragStart = null;
                if (hoverWindow is { } w && hover is { } h) Finish(new Result.Window(w, h with { X = h.X + Virtual.X, Y = h.Y + Virtual.Y }));
                else Finish(new Result.Display(DisplayUnderMouse()));
                return IntPtr.Zero;
            }
            case WM_RBUTTONUP:
                Finish(new Result.Cancelled());
                return IntPtr.Zero;
            case WM_KEYDOWN or WM_SYSKEYDOWN:
                switch ((int)wParam)
                {
                    case VK_ESCAPE: Finish(new Result.Cancelled()); break;
                    case VK_SPACE or VK_RETURN: Finish(new Result.Display(DisplayUnderMouse())); break;
                    case 0x43: // C: copy the colour under the pointer
                    {
                        int fx = mouseX - Virtual.X, fy = mouseY - Virtual.Y;
                        if (fx >= 0 && fy >= 0 && fx < Frozen.Width && fy < Frozen.Height)
                        {
                            var c = Frozen.GetPixel(fx, fy);
                            var hex = $"#{c.Red:X2}{c.Green:X2}{c.Blue:X2}";
                            RasterNest.Windows.Clipboard.CopyText(hex);
                            toast = $"Copied {hex}";
                            InvalidateRect(hwnd, IntPtr.Zero, false);
                        }
                        break;
                    }
                }
                return IntPtr.Zero;
            case WM_KILLFOCUS:
                // Another window took over (e.g. a notification); keep the overlay unless we're done.
                return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private static IntPtr StaticWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (active is { } a && (a.hwnd == hwnd || a.hwnd == IntPtr.Zero))
        {
            if (a.hwnd == IntPtr.Zero) a.hwnd = hwnd;
            return a.Handle(msg, wParam, lParam);
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    /// <summary>Pixels of an area of the frozen screen.</summary>
    public SKBitmap Crop(RectI r)
    {
        var local = new SKRectI(r.X - Virtual.X, r.Y - Virtual.Y, r.Right - Virtual.X, r.Bottom - Virtual.Y);
        local.Intersect(new SKRectI(0, 0, Frozen.Width, Frozen.Height));
        using var subset = new SKBitmap();
        Frozen.ExtractSubset(subset, local);
        return subset.Copy();
    }

    public double ScaleAt(RectI r)
    {
        int cx = r.X + r.W / 2, cy = r.Y + r.H / 2;
        return displays.FirstOrDefault(d => cx >= d.X && cx < d.X + d.Width && cy >= d.Y && cy < d.Y + d.Height)?.Scale ?? 1;
    }

    public void Dispose()
    {
        if (active == this) active = null;
        foreach (var (dc, bmp) in new[] { (backDc, backBmp), (brightDc, brightBmp), (dimDc, dimBmp) })
        {
            if (dc != IntPtr.Zero) DeleteDC(dc);
            if (bmp != IntPtr.Zero) DeleteObject(bmp);
        }
        Frozen.Dispose();
    }
}
