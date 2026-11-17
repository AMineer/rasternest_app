using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace RasterNest.App.Editor;

/// <summary>
/// A thin grip on a panel's edge: drag it to make the panel wider or narrower. Double-click restores the default.
/// </summary>
internal sealed class Splitter : Grid
{
    private static readonly System.Reflection.PropertyInfo? CursorProperty =
        typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);

    private readonly Func<double> get;
    private readonly Action<double> set;
    private readonly double min, max, fallback;
    private readonly int direction;
    private double startX, startWidth;
    private bool dragging;

    /// <param name="edge">Which edge of the panel the grip sits on (Right for a left-hand panel).</param>
    public Splitter(HorizontalAlignment edge, Func<double> get, Action<double> set, double min, double max, double fallback, Action? finished = null)
    {
        this.get = get;
        this.set = set;
        this.min = min;
        this.max = max;
        this.fallback = fallback;
        direction = edge == HorizontalAlignment.Right ? 1 : -1;
        Width = 6;
        HorizontalAlignment = edge;
        VerticalAlignment = VerticalAlignment.Stretch;
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        Canvas.SetZIndex(this, 10);
        ToolTipService.SetToolTip(this, "Drag to resize · double-click to reset");

        CursorProperty?.SetValue(this, InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast));
        PointerEntered += (_, _) => Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
        PointerExited += (_, _) => { if (!dragging) Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); };
        PointerPressed += (_, e) =>
        {
            dragging = true;
            startX = e.GetCurrentPoint(null).Position.X;
            startWidth = this.get();
            CapturePointer(e.Pointer);
            e.Handled = true;
        };
        PointerMoved += (_, e) =>
        {
            if (!dragging) return;
            var dx = e.GetCurrentPoint(null).Position.X - startX;
            this.set(Math.Clamp(startWidth + dx * direction, this.min, this.max));
            e.Handled = true;
        };
        PointerReleased += (_, e) =>
        {
            if (!dragging) return;
            dragging = false;
            ReleasePointerCapture(e.Pointer);
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            finished?.Invoke();
        };
        DoubleTapped += (_, _) => { this.set(this.fallback); finished?.Invoke(); };
    }
}
