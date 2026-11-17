using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using RasterNest.App.Shell;
using Windows.System;
using Windows.UI.Core;
using static RasterNest.App.Shell.Win32;

namespace RasterNest.App;

/// <summary>Settings, with the same options as the Mac app. Changes apply immediately.</summary>
internal sealed class SettingsWindow : Window
{
    private static SettingsWindow? shared;
    internal static SettingsWindow? Current => shared;

    public static void ShowShared()
    {
        if (shared == null)
        {
            shared = new SettingsWindow();
            shared.Closed += (_, _) => shared = null;
        }
        shared.Activate();
    }

    private readonly AppSettings s = AppSettings.Shared;
    private readonly StackPanel panel = new() { Spacing = 14, Padding = new Thickness(24, 20, 24, 24), HorizontalAlignment = HorizontalAlignment.Stretch };

    private SettingsWindow()
    {
        Title = "RasterNest Settings";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "rasternest.ico"));
        // A compact window that always fits the screen; the content scrolls.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        int w = Math.Min((int)(560 * scale), (int)(area.Width * 0.9)), h = Math.Min((int)(640 * scale), (int)(area.Height * 0.85));
        AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Build();
    }

    private void Build()
    {
        panel.Children.Clear();
        Section("After capturing");
        Toggle("Open the editor", s.OpenEditor, v => s.OpenEditor = v);
        Toggle("Copy to the clipboard", s.CopyToClipboard, v => s.CopyToClipboard = v);
        Toggle("Keep a PNG beside each capture", s.KeepPng, v => s.KeepPng = v,
               "The editable .rasternest is always kept; the PNG is the finished picture, refreshed on every save.");
        Toggle("Include the mouse pointer", s.CaptureCursor, v => s.CaptureCursor = v);

        Section("Captures folder");
        var folder = new TextBlock { Text = s.SaveFolder, TextWrapping = TextWrapping.Wrap, Opacity = 0.8 };
        var change = new Button { Content = "Change…" };
        change.Click += async (_, _) =>
        {
            var picker = new global::Windows.Storage.Pickers.FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            if (await picker.PickSingleFolderAsync() is { } f)
            {
                s.SaveFolder = f.Path;
                s.Save();
                folder.Text = f.Path;
                Library.CaptureLibrary.Shared.Reload();
            }
        };
        var open = new Button { Content = "Open" };
        open.Click += (_, _) => { Directory.CreateDirectory(s.SaveFolder); System.Diagnostics.Process.Start("explorer.exe", $"\"{s.SaveFolder}\""); };
        panel.Children.Add(folder);
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { change, open } });

        Section("Keyboard shortcuts");
        if (App.FailedHotKeys.Count > 0)
            panel.Children.Add(new InfoBar
            {
                IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = "Some shortcuts are taken",
                Message = $"Another app already uses {string.Join(", ", App.FailedHotKeys)}. If Print Screen doesn't work, turn off " +
                          "\"Use the Print screen key to open screen capture\" in Windows Settings › Accessibility › Keyboard, or pick other keys.",
            });
        Shortcut("Capture area or window", s.CaptureHotKey, k => s.CaptureHotKey = k);
        Shortcut("Capture full screen", s.FullScreenHotKey, k => s.FullScreenHotKey = k);
        Shortcut("Record screen", s.RecordHotKey, k => s.RecordHotKey = k);
        Shortcut("Grab text", s.TextHotKey, k => s.TextHotKey = k);

        Section("Recording");
        Toggle("Highlight clicks", s.ShowClicks, v => s.ShowClicks = v, "Coming to Windows soon.");
        Toggle("Show keystrokes", s.ShowKeystrokes, v => s.ShowKeystrokes = v, "Coming to Windows soon.");

        Section("Command line");
        panel.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, Opacity = 0.8,
            Text = "rnest captures, annotates and records from scripts and AI agents (rnest mcp). Install it with: winget install A2M4.rnest",
        });
    }

    private void Section(string title) =>
        panel.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) });

    private void Toggle(string label, bool value, Action<bool> set, string? help = null)
    {
        var t = new ToggleSwitch { Header = label, IsOn = value };
        t.Toggled += (_, _) => { set(t.IsOn); s.Save(); };
        panel.Children.Add(t);
        if (help != null) panel.Children.Add(new TextBlock { Text = help, TextWrapping = TextWrapping.Wrap, Opacity = 0.6, FontSize = 12, Margin = new Thickness(0, -8, 0, 0) });
    }

    /// <summary>A row with the shortcut; click Change, then press the new keys (Esc cancels, Backspace turns it off).</summary>
    private void Shortcut(string label, HotKey? current, Action<HotKey?> set)
    {
        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Width = 190, TextWrapping = TextWrapping.Wrap };
        var button = new Button { Content = current?.ToString() ?? "Off", MinWidth = 160 };
        var recording = false;
        button.Click += (_, _) =>
        {
            recording = true;
            button.Content = "Press keys…";
        };
        button.PreviewKeyDown += (_, e) =>
        {
            if (!recording) return;
            e.Handled = true;
            var key = (uint)e.Key;
            if (e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows or VirtualKey.RightWindows
                or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftShift or VirtualKey.RightShift) return;
            recording = false;
            if (e.Key == VirtualKey.Escape) { button.Content = current?.ToString() ?? "Off"; return; }
            if (e.Key == VirtualKey.Back) { set(null); s.Save(); current = null; button.Content = "Off"; return; }
            uint mods = 0;
            bool Down(VirtualKey k) => InputKeyboardSource.GetKeyStateForCurrentThread(k).HasFlag(CoreVirtualKeyStates.Down);
            if (Down(VirtualKey.Control)) mods |= MOD_CONTROL;
            if (Down(VirtualKey.Shift)) mods |= MOD_SHIFT;
            if (Down(VirtualKey.Menu)) mods |= MOD_ALT;
            if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) mods |= MOD_WIN;
            var hk = new HotKey(key, mods);
            set(hk);
            s.Save();
            current = hk;
            button.Content = hk.ToString();
        };
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { text, button } });
    }
}
