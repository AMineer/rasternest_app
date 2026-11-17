using System.Runtime.InteropServices;
using static RasterNest.App.Shell.Win32;

namespace RasterNest.App.Shell;

/// <summary>
/// A hidden message window that owns the notification-area icon, its menu and the global shortcuts.
/// It lives on the UI thread, so its callbacks can touch WinUI directly.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    public sealed record MenuItem(string Title, Action? Action = null, IReadOnlyList<MenuItem>? Children = null,
                                  bool Enabled = true, string? Shortcut = null)
    {
        public static MenuItem Separator => new("-");
        public bool IsSeparator => Title == "-";
    }

    private const uint CallbackMessage = WM_APP + 1;
    private static readonly WndProc Proc = StaticWndProc; // kept alive for the window's lifetime
    private static TrayIcon? current;

    private readonly IntPtr hwnd;
    private readonly IntPtr icon;
    private readonly Dictionary<int, Action> hotKeyActions = [];
    private bool added;

    /// <summary>Builds the menu each time it opens (so recent captures and shortcuts are current).</summary>
    public Func<IReadOnlyList<MenuItem>>? MenuProvider { get; set; }
    /// <summary>Left click on the icon.</summary>
    public Action? Clicked { get; set; }

    public IntPtr Handle => hwnd;

    public TrayIcon(string tooltip, string iconPath)
    {
        current = this;
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Proc,
            hInstance = GetModuleHandle(null),
            lpszClassName = "RasterNestTray",
        };
        var atom = RegisterClassEx(ref wc);
        var classError = Marshal.GetLastWin32Error();
        hwnd = CreateWindowEx(0, "RasterNestTray", "RasterNest", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        var windowError = Marshal.GetLastWin32Error();
        icon = LoadImage(IntPtr.Zero, iconPath, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
        Log.Write($"tray: class={atom} (err {classError}) hwnd={hwnd} (err {windowError}) icon={icon} path={iconPath} size={Marshal.SizeOf<NOTIFYICONDATA>()}");
        var data = Data(tooltip);
        data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
        added = Shell_NotifyIcon(NIM_ADD, ref data);
        Log.Write($"tray: NIM_ADD={added} err={Marshal.GetLastWin32Error()}");
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIcon(NIM_SETVERSION, ref data);
    }

    private NOTIFYICONDATA Data(string tip = "RasterNest") => new()
    {
        cbSize = Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = hwnd, uID = 1, uCallbackMessage = CallbackMessage, hIcon = icon,
        szTip = tip, szInfo = "", szInfoTitle = "",
    };

    /// <summary>A short Windows notification from the tray icon (the Windows counterpart of the Mac's HUD).</summary>
    public void Notify(string title, string message)
    {
        var data = Data();
        data.uFlags = NIF_INFO;
        data.szInfoTitle = title;
        data.szInfo = message;
        data.dwInfoFlags = NIIF_USER | NIIF_NOSOUND;
        data.hBalloonIcon = icon;
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    // MARK: shortcuts

    /// <summary>Registers a global shortcut. Returns false if another app already uses it.</summary>
    public bool RegisterHotKey(int id, HotKey key, Action action)
    {
        hotKeyActions[id] = action;
        return Win32.RegisterHotKey(hwnd, id, key.Modifiers | MOD_NOREPEAT, key.VirtualKey);
    }

    public void UnregisterHotKeys()
    {
        foreach (var id in hotKeyActions.Keys) UnregisterHotKey(hwnd, id);
        hotKeyActions.Clear();
    }

    // MARK: menu

    private void ShowMenu()
    {
        var items = MenuProvider?.Invoke() ?? [];
        var actions = new Dictionary<uint, Action>();
        var menu = Build(items, actions);
        GetCursorPos(out var p);
        SetForegroundWindow(hwnd); // so the menu closes when you click elsewhere
        var chosen = TrackPopupMenuEx(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_BOTTOMALIGN, p.X, p.Y, hwnd, IntPtr.Zero);
        PostMessage(hwnd, WM_NULL, IntPtr.Zero, IntPtr.Zero);
        DestroyMenu(menu);
        if (chosen != 0 && actions.TryGetValue(chosen, out var action)) action();
    }

    private static IntPtr Build(IReadOnlyList<MenuItem> items, Dictionary<uint, Action> actions)
    {
        var menu = CreatePopupMenu();
        foreach (var item in items)
        {
            if (item.IsSeparator) { AppendMenu(menu, MF_SEPARATOR, UIntPtr.Zero, null); continue; }
            var text = item.Shortcut != null ? $"{item.Title}\t{item.Shortcut}" : item.Title;
            if (item.Children is { } children)
            {
                AppendMenu(menu, MF_POPUP | (item.Enabled ? 0 : MF_GRAYED), (UIntPtr)(ulong)Build(children, actions), text);
                continue;
            }
            var id = (uint)actions.Count + 1;
            if (item.Action != null) actions[id] = item.Action;
            AppendMenu(menu, MF_STRING | (item.Enabled && item.Action != null ? 0 : MF_GRAYED), (UIntPtr)id, text);
        }
        return menu;
    }

    private static IntPtr StaticWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        var self = current;
        if (self != null)
        {
            if (msg == WM_HOTKEY) Log.Write($"hotkey {(int)wParam}");
            if (msg == WM_HOTKEY && self.hotKeyActions.TryGetValue((int)wParam, out var action))
            {
                action();
                return IntPtr.Zero;
            }
            if (msg == CallbackMessage)
            {
                // NOTIFYICON_VERSION_4: the event is in the low word of lParam.
                switch ((uint)LoWord(lParam))
                {
                    case WM_CONTEXTMENU or WM_RBUTTONUP: self.ShowMenu(); break;
                    case NIN_SELECT or NIN_KEYSELECT or WM_LBUTTONUP: (self.Clicked ?? self.ShowMenu)(); break;
                }
                return IntPtr.Zero;
            }
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    public void Dispose()
    {
        UnregisterHotKeys();
        if (added)
        {
            var data = Data();
            Shell_NotifyIcon(NIM_DELETE, ref data);
            added = false;
        }
        DestroyWindow(hwnd);
    }
}

/// <summary>A global shortcut: a virtual key plus MOD_ALT/CONTROL/SHIFT/WIN.</summary>
public sealed record HotKey(uint VirtualKey, uint Modifiers)
{
    public override string ToString()
    {
        var parts = new List<string>();
        if ((Modifiers & MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((Modifiers & MOD_ALT) != 0) parts.Add("Alt");
        if ((Modifiers & MOD_SHIFT) != 0) parts.Add("Shift");
        if ((Modifiers & MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyName(VirtualKey));
        return string.Join("+", parts);
    }

    public static string KeyName(uint vk) => vk switch
    {
        0x2C => "Print Screen",
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x20 => "Space",
        0x13 => "Pause",
        0x91 => "Scroll Lock",
        _ => $"Key {vk}",
    };
}
