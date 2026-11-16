using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Serialization;
using RasterNest.Core;
using RasterNest.Render;
using SkiaSharp;
using static RasterNest.Windows.Native;

namespace RasterNest.Windows;

/// <summary>Same JSON as the Mac/Linux <c>rnest displays --json</c>. Coordinates are physical pixels on Windows.</summary>
public sealed record DisplayDescriptor(int Index, uint Id, string Name, double X, double Y, double Width, double Height, double Scale, bool IsMain);

/// <summary>Same JSON as the Mac/Linux <c>rnest windows --json</c>. Coordinates are physical pixels on Windows.</summary>
public sealed record WindowDescriptor(uint Id, string Owner, string Title, double X, double Y, double Width, double Height)
{
    /// <summary>The process name (e.g. "msedge"), for matching alongside the friendly owner name.</summary>
    [JsonIgnore] public string Process { get; init; } = "";
}

public sealed class CaptureException(string message) : Exception(message);

/// <summary>A captured image and its pixels-per-point scale (1.5 on a 150% display).</summary>
public sealed record Captured(SKBitmap Bitmap, double Scale)
{
    public byte[] Png() => ImageCodec.EncodePng(Bitmap, Scale);
}

/// <summary>
/// Screen and window capture with GDI. PrintWindow(PW_RENDERFULLCONTENT) captures a window even when other
/// windows cover it, and (unlike Windows.Graphics.Capture) shows no yellow border and needs no consent.
/// Captures need an interactive desktop: they fail from a service or an SSH session.
/// </summary>
public static class ScreenCapture
{
    static ScreenCapture() => EnsureDpiAware();

    public static List<DisplayDescriptor> Displays()
    {
        var list = new List<(IntPtr Handle, MONITORINFOEX Info)>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr hdc, ref RECT rc, IntPtr data) =>
        {
            var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(h, ref info)) list.Add((h, info));
            return true;
        }, IntPtr.Zero);
        // Main display first, then left to right, so index 0 matches the Mac's "main display".
        var ordered = list.OrderByDescending(m => (m.Info.dwFlags & MONITORINFOF_PRIMARY) != 0)
                          .ThenBy(m => m.Info.rcMonitor.Left).ThenBy(m => m.Info.rcMonitor.Top).ToList();
        return ordered.Select((m, i) =>
        {
            var r = m.Info.rcMonitor;
            return new DisplayDescriptor(i, (uint)m.Handle.ToInt64(), m.Info.szDevice.TrimStart('\\', '.'), r.Left, r.Top, r.Width, r.Height,
                                         ScaleOf(m.Handle), (m.Info.dwFlags & MONITORINFOF_PRIMARY) != 0);
        }).ToList();
    }

    private static double ScaleOf(IntPtr monitor) =>
        GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1;

    /// <summary>On-screen top-level windows, front to back.</summary>
    public static List<WindowDescriptor> Windows()
    {
        var result = new List<WindowDescriptor>();
        var names = new Dictionary<uint, (string Friendly, string Process)>();
        var self = (uint)Environment.ProcessId;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            var ex = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
            if ((ex & WS_EX_TOOLWINDOW) != 0) return true;
            if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var title = Title(hwnd);
            var r = Bounds(hwnd);
            if (r.Width < 2 || r.Height < 2) return true;
            GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == self) return true;
            if (title.Length == 0 && (ex & WS_EX_NOACTIVATE) != 0) return true;
            if (!names.TryGetValue(pid, out var n)) names[pid] = n = ProcessNames(pid);
            if (n.Process.Equals("explorer", StringComparison.OrdinalIgnoreCase) && ClassName(hwnd) is "Progman" or "WorkerW" or "Shell_TrayWnd")
                return true;
            // Store apps (Settings, Calculator…) live inside ApplicationFrameHost; their title is the app's name.
            var owner = n.Process.Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase) && title.Length > 0 ? title : n.Friendly;
            result.Add(new WindowDescriptor((uint)hwnd.ToInt64(), owner, title, r.Left, r.Top, r.Width, r.Height) { Process = n.Process });
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private static string Title(IntPtr hwnd)
    {
        var len = GetWindowTextLength(hwnd);
        if (len <= 0) return "";
        var buf = new char[len + 1];
        var n = GetWindowText(hwnd, buf, buf.Length);
        return new string(buf, 0, n);
    }

    private static string ClassName(IntPtr hwnd)
    {
        var buf = new char[256];
        var n = GetClassName(hwnd, buf, buf.Length);
        return new string(buf, 0, n);
    }

    private static (string Friendly, string Process) ProcessNames(uint pid)
    {
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById((int)pid);
            var name = p.ProcessName;
            string? friendly = null;
            try { friendly = p.MainModule?.FileVersionInfo.FileDescription; } catch { /* elevated or protected process */ }
            return (string.IsNullOrWhiteSpace(friendly) ? name : friendly.Trim(), name);
        }
        catch { return ("", ""); }
    }

    /// <summary>The visible window frame (without the invisible resize borders Windows 10/11 add).</summary>
    private static RECT Bounds(IntPtr hwnd)
    {
        if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf<RECT>()) == 0) return r;
        GetWindowRect(hwnd, out r);
        return r;
    }

    /// <summary>
    /// The front-most sizable window whose owner/process contains app, title contains title, and either contains window.
    /// </summary>
    public static WindowDescriptor FindWindow(string? app, string? title, string? window)
    {
        var list = Windows();
        static bool Has(string s, string? needle) =>
            string.IsNullOrEmpty(needle) || s.Contains(needle, StringComparison.OrdinalIgnoreCase);
        var match = list.FirstOrDefault(w =>
            w.Width >= 80 && w.Height >= 60 &&
            (window == null || Has(w.Owner, window) || Has(w.Process, window) || Has(w.Title, window)) &&
            (Has(w.Owner, app) || Has(w.Process, app)) && Has(w.Title, title));
        if (match != null) return match;
        var wanted = string.Join(" / ", new[] { window, app, title }.Where(s => s != null));
        var seen = string.Join(", ", list.Select(w => w.Process).Where(s => s.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Order().Take(30));
        throw new CaptureException($"No on-screen window matches {wanted}. Apps with windows: {seen}");
    }

    public static Captured CaptureDisplay(int? index, bool cursor = false)
    {
        var displays = Displays();
        if (displays.Count == 0) throw new CaptureException("No display found. Captures need a signed-in desktop session.");
        var d = index is { } i ? displays.ElementAtOrDefault(i) ?? throw new CaptureException($"There's no display {i}. See `rnest displays`.") : displays[0];
        return Capture(new RECT { Left = (int)d.X, Top = (int)d.Y, Right = (int)(d.X + d.Width), Bottom = (int)(d.Y + d.Height) }, d.Scale, cursor);
    }

    /// <summary>An area of the screen, in physical pixels of the virtual desktop.</summary>
    public static Captured CaptureRect(RectD rect, bool cursor = false)
    {
        var r = new RECT { Left = (int)Math.Round(rect.MinX), Top = (int)Math.Round(rect.MinY), Right = (int)Math.Round(rect.MaxX), Bottom = (int)Math.Round(rect.MaxY) };
        return Capture(r, ScaleOf(MonitorFromRect(ref r, MONITOR_DEFAULTTONEAREST)), cursor);
    }

    private static Captured Capture(RECT r, double scale, bool cursor)
    {
        if (r.Width <= 0 || r.Height <= 0) throw new CaptureException("The area to capture is empty.");
        var screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) throw new CaptureException("Couldn't reach the screen. Captures need a signed-in desktop session.");
        try
        {
            return WithDib(r.Width, r.Height, (dc, bits) =>
            {
                if (!BitBlt(dc, 0, 0, r.Width, r.Height, screen, r.Left, r.Top, SRCCOPY | CAPTUREBLT))
                    throw new CaptureException("Couldn't read the screen. Captures need a signed-in, unlocked desktop session.");
                if (cursor) DrawCursor(dc, r.Left, r.Top);
                return new Captured(ToBitmap(bits, r.Width, r.Height), scale);
            });
        }
        finally { ReleaseDC(IntPtr.Zero, screen); }
    }

    /// <summary>One window, even if other windows cover it.</summary>
    public static Captured CaptureWindow(uint id, bool cursor = false)
    {
        var hwnd = new IntPtr(id);
        if (!IsWindow(hwnd)) throw new CaptureException($"There's no window {id}. See `rnest windows`.");
        if (IsIconic(hwnd)) throw new CaptureException("That window is minimized. Restore it first.");
        GetWindowRect(hwnd, out var outer);
        var visible = Bounds(hwnd);
        var dpi = GetDpiForWindow(hwnd);
        var scale = dpi > 0 ? dpi / 96.0 : 1;
        var full = WithDib(outer.Width, outer.Height, (dc, bits) =>
        {
            if (!PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)) throw new CaptureException("Windows couldn't draw that window.");
            if (cursor) DrawCursor(dc, outer.Left, outer.Top);
            return ToBitmap(bits, outer.Width, outer.Height);
        });
        // Trim the invisible resize border around Windows 10/11 windows.
        var crop = SKRectI.Create(Math.Max(0, visible.Left - outer.Left), Math.Max(0, visible.Top - outer.Top),
                                  Math.Min(visible.Width, outer.Width), Math.Min(visible.Height, outer.Height));
        if (IsZoomed(hwnd))
        {
            // PrintWindow draws maximized windows lower and further right than their frame says, leaving pure black
            // rows/columns where the border would be. Skip them (a real title bar is never entirely #000000).
            var border = Math.Max(crop.Left, crop.Top) * 2 + 2;
            int dy = BlankRows(full, crop, border), dx = BlankColumns(full, crop, border);
            crop = SKRectI.Create(crop.Left + dx, crop.Top + dy, Math.Min(crop.Width, full.Width - crop.Left - dx), Math.Min(crop.Height, full.Height - crop.Top - dy));
        }
        if (crop.Width <= 0 || crop.Height <= 0 || crop == SKRectI.Create(0, 0, full.Width, full.Height)) return new Captured(full, scale);
        var cropped = new SKBitmap(crop.Width, crop.Height, full.ColorType, full.AlphaType);
        full.ExtractSubset(cropped, crop);
        var copy = cropped.Copy();
        cropped.Dispose();
        full.Dispose();
        return new Captured(copy, scale);
    }

    private static bool IsBlack(SKColor c) => c.Red == 0 && c.Green == 0 && c.Blue == 0;

    private static int BlankRows(SKBitmap b, SKRectI crop, int max)
    {
        var n = 0;
        for (var y = crop.Top; y < Math.Min(b.Height, crop.Top + max); y++, n++)
            for (var x = crop.Left; x < crop.Right; x += 3)
                if (!IsBlack(b.GetPixel(x, y))) return n;
        return n;
    }

    private static int BlankColumns(SKBitmap b, SKRectI crop, int max)
    {
        var n = 0;
        for (var x = crop.Left; x < Math.Min(b.Width, crop.Left + max); x++, n++)
            for (var y = crop.Top; y < crop.Bottom; y += 3)
                if (!IsBlack(b.GetPixel(x, y))) return n;
        return n;
    }

    private static T WithDib<T>(int w, int h, Func<IntPtr, IntPtr, T> body)
    {
        var screen = GetDC(IntPtr.Zero);
        var dc = CreateCompatibleDC(screen);
        var header = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        var dib = CreateDIBSection(dc, ref header, 0, out var bits, IntPtr.Zero, 0);
        if (dib == IntPtr.Zero) { DeleteDC(dc); ReleaseDC(IntPtr.Zero, screen); throw new CaptureException("Out of memory for the capture."); }
        var old = SelectObject(dc, dib);
        try { return body(dc, bits); }
        finally
        {
            SelectObject(dc, old);
            DeleteObject(dib);
            DeleteDC(dc);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private static unsafe SKBitmap ToBitmap(IntPtr bits, int w, int h)
    {
        var bmp = new SKBitmap(new SKImageInfo(w, h, SKColorType.Bgra8888, SKAlphaType.Opaque));
        var src = (byte*)bits;
        var dst = (byte*)bmp.GetPixels();
        var n = w * h;
        Buffer.MemoryCopy(src, dst, (long)n * 4, (long)n * 4);
        // GDI leaves alpha undefined; make every pixel opaque.
        for (var i = 3; i < n * 4; i += 4) dst[i] = 255;
        bmp.NotifyPixelsChanged();
        return bmp;
    }

    private static void DrawCursor(IntPtr dc, int originX, int originY)
    {
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref info) || (info.flags & CURSOR_SHOWING) == 0 || info.hCursor == IntPtr.Zero) return;
        if (!GetIconInfo(info.hCursor, out var icon)) return;
        try
        {
            DrawIconEx(dc, info.ptScreenPos.X - icon.xHotspot - originX, info.ptScreenPos.Y - icon.yHotspot - originY,
                       info.hCursor, 0, 0, 0, IntPtr.Zero, DI_NORMAL);
        }
        finally
        {
            if (icon.hbmMask != IntPtr.Zero) DeleteObject(icon.hbmMask);
            if (icon.hbmColor != IntPtr.Zero) DeleteObject(icon.hbmColor);
        }
    }

    /// <summary>Captures what a guide step or MCP call describes.</summary>
    public static Captured Capture(CaptureSpec spec, string? baseDirectory)
    {
        if (spec.File is { } file)
        {
            var path = Path.GetFullPath(file, baseDirectory ?? Environment.CurrentDirectory);
            var decoded = ImageCodec.Load(path) ?? throw new CaptureException($"Couldn't read {file} as an image.");
            return new Captured(decoded.Bitmap, decoded.Scale);
        }
        var cursor = spec.Cursor == true;
        if (spec.Window != null || spec.App != null)
            return CaptureWindow(FindWindow(spec.App, spec.Title, spec.Window).Id, cursor);
        if (spec.Rect is { } r)
        {
            if (r.Count != 4 || r[2] <= 0 || r[3] <= 0) throw new CaptureException("`rect` must be [x, y, width, height].");
            return CaptureRect(new RectD(r[0], r[1], r[2], r[3]), cursor);
        }
        return CaptureDisplay(spec.Display, cursor);
    }
}
