using Microsoft.UI.Windowing;
using RasterNest.App.Editor;

namespace RasterNest.App.Shell;

/// <summary>
/// Gets RasterNest's own windows out of the way for a capture started from the editor's menus,
/// and brings them back afterwards (whether the capture finished or was cancelled).
/// </summary>
internal static class WindowHider
{
    private static List<AppWindow>? hidden;

    public static bool IsHiding => hidden != null;

    public static async Task HideAsync()
    {
        if (hidden != null) return;
        hidden = new[] { EditorWindow.Current?.AppWindow, SettingsWindow.Current?.AppWindow }
            .OfType<AppWindow>().Where(w => w.IsVisible).ToList();
        foreach (var w in hidden) w.Hide();
        // Give Windows a moment to repaint what was behind them before the screen is frozen.
        if (hidden.Count > 0) await Task.Delay(300);
    }

    public static void Restore()
    {
        if (hidden == null) return;
        foreach (var w in hidden)
        {
            try { w.Show(true); } catch { /* closed meanwhile */ }
        }
        hidden = null;
    }
}
