using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace RasterNest.App.Capture;

/// <summary>
/// A small floating bar shown while recording (or during a scrolling capture): status, a running timer,
/// and Stop/Done plus Cancel. Windows is told to leave it out of captures, so it never appears in the video.
/// </summary>
internal sealed class CaptureBar
{
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
    private const uint WDA_EXCLUDEFROMCAPTURE = 0x11;

    private readonly Window window = new();
    private readonly TextBlock status = new() { Foreground = new SolidColorBrush(Colors.White), VerticalAlignment = VerticalAlignment.Center, FontSize = 13 };
    private readonly TextBlock timer = new()
    {
        Foreground = new SolidColorBrush(Colors.White), VerticalAlignment = VerticalAlignment.Center, FontSize = 13,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"), MinWidth = 44,
    };
    private readonly Stopwatch clock = new();
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private bool closed;

    public CaptureBar(string text, string primary, Action onPrimary, Action? onCancel = null, bool pulse = true)
    {
        status.Text = text;
        var dot = new Ellipse { Width = 10, Height = 10, Fill = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 239, 68, 68)), VerticalAlignment = VerticalAlignment.Center };
        var stop = new Button
        {
            Content = primary, Padding = new Thickness(14, 4, 14, 4),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 239, 68, 68)), Foreground = new SolidColorBrush(Colors.White),
        };
        stop.Click += (_, _) => { Close(); onPrimary(); };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(14, 8, 8, 8), VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(dot);
        row.Children.Add(status);
        row.Children.Add(timer);
        row.Children.Add(stop);
        if (onCancel != null)
        {
            var cancel = new Button { Content = "Cancel", Padding = new Thickness(10, 4, 10, 4), Foreground = new SolidColorBrush(Colors.White),
                                      Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(60, 255, 255, 255)) };
            cancel.Click += (_, _) => { Close(); onCancel(); };
            row.Children.Add(cancel);
        }
        window.Content = new Border
        {
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(240, 24, 24, 28)), CornerRadius = new CornerRadius(10), Child = row,
        };
        var presenter = OverlappedPresenter.CreateForToolWindow();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMinimizable = false;
        presenter.IsMaximizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.IsShownInSwitchers = false;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        var scale = Shell.Win32.GetDpiForWindow(hwnd) / 96.0;
        Shell.Win32.GetCursorPos(out var p);
        var area = DisplayArea.GetFromPoint(new global::Windows.Graphics.PointInt32(p.X, p.Y), DisplayAreaFallback.Primary).WorkArea;
        int w = (int)((onCancel != null ? 420 : 330) * scale), h = (int)(48 * scale);
        window.AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (int)(12 * scale), w, h));

        tick.Tick += (_, _) =>
        {
            var t = clock.Elapsed;
            timer.Text = $"{(int)t.TotalMinutes}:{t.Seconds:00}";
            if (pulse) dot.Opacity = t.Milliseconds < 500 ? 1 : 0.35;
        };
    }

    public void Show()
    {
        clock.Start();
        tick.Start();
        window.AppWindow.Show(false);
    }

    public void SetStatus(string text) => status.Text = text;

    public void Close()
    {
        if (closed) return;
        closed = true;
        tick.Stop();
        window.Close();
    }
}
