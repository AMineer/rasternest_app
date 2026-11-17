using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace RasterNest.App.Capture;

/// <summary>A small 3-2-1 badge in the middle of the screen before a recording starts.</summary>
internal sealed class CountdownWindow
{
    private readonly Window window = new();
    private readonly TextBlock number = new()
    {
        FontSize = 72, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Foreground = new SolidColorBrush(Colors.White),
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
    };
    private bool shown;

    public CountdownWindow()
    {
        window.Content = new Grid
        {
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(235, 20, 20, 24)),
            Children = { number },
        };
        var presenter = OverlappedPresenter.CreateForDialog();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.SetBorderAndTitleBar(false, false);
        window.AppWindow.SetPresenter(presenter);
        window.AppWindow.IsShownInSwitchers = false;
        var scale = Shell.Win32.GetDpiForSystem() / 96.0;
        var size = (int)(140 * scale);
        var area = DisplayArea.GetFromPoint(Cursor(), DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(area.X + (area.Width - size) / 2, area.Y + (area.Height - size) / 2, size, size));
    }

    private static global::Windows.Graphics.PointInt32 Cursor()
    {
        Shell.Win32.GetCursorPos(out var p);
        return new global::Windows.Graphics.PointInt32(p.X, p.Y);
    }

    public void Show(int n)
    {
        number.Text = n.ToString();
        if (!shown) { window.AppWindow.Show(false); shown = true; }
    }

    public void Close() => window.Close();
}
