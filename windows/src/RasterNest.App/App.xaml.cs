using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using RasterNest.App.Capture;
using RasterNest.App.Editor;
using RasterNest.App.Library;
using RasterNest.App.Shell;
using RasterNest.Core;
using Windows.ApplicationModel.Activation;

namespace RasterNest.App;

/// <summary>
/// RasterNest lives in the notification area: no main window, a tray menu, global shortcuts,
/// and the editor when there's something to edit.
/// </summary>
public partial class App : Application
{
    private TrayIcon? tray;
    private CaptureCoordinator? capture;
    private DispatcherQueue? dispatcher;
    internal static App? CurrentApp { get; private set; }

    public App()
    {
        InitializeComponent();
        CurrentApp = this;
        // Keep running with no windows open (we live in the tray).
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            e.Handled = true;
            Log.Write($"unhandled: {e.Exception}");
            tray?.Notify("Something went wrong", e.Message);
        };
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        dispatcher = DispatcherQueue.GetForCurrentThread();
        RasterNest.Windows.ScreenCapture.Displays(); // sets per-monitor DPI awareness early
        tray = new TrayIcon("RasterNest", Path.Combine(AppContext.BaseDirectory, "Assets", "rasternest.ico"));
        capture = new CaptureCoordinator((title, message) => tray.Notify(title, message));
        tray.MenuProvider = BuildMenu;
        RegisterHotKeys();
        AppSettings.Changed += RegisterHotKeys;
        CaptureLibrary.Shared.Reload();

        Log.Write("launched: tray and shortcuts ready");
        AppInstance.GetCurrent().Activated += (_, e) =>
        {
            Log.Write($"activated (redirected): {e.Kind}");
            dispatcher.TryEnqueue(() => HandleActivation(e));
        };
        HandleActivation(AppInstance.GetCurrent().GetActivatedEventArgs());

        if (!AppSettings.Shared.HasOnboarded)
        {
            AppSettings.Shared.HasOnboarded = true;
            AppSettings.Shared.Save();
            tray.Notify("RasterNest is running", $"Press {AppSettings.Shared.CaptureHotKey?.ToString() ?? "the tray icon"} to capture. RasterNest lives in the notification area.");
        }
    }

    /// <summary>Files and rasternest:// links opened from Explorer, rnest edit, or a second launch.</summary>
    private void HandleActivation(AppActivationArguments args)
    {
        Log.Write($"handle activation: {args.Kind} {(args.Data as ILaunchActivatedEventArgs)?.Arguments}");
        try
        {
            switch (args.Kind)
            {
                case ExtendedActivationKind.File when args.Data is IFileActivatedEventArgs f:
                    foreach (var file in f.Files) OpenPath(file.Path);
                    break;
                case ExtendedActivationKind.Protocol when args.Data is IProtocolActivatedEventArgs p:
                    HandleUri(p.Uri);
                    break;
                case ExtendedActivationKind.Launch when args.Data is ILaunchActivatedEventArgs l && !string.IsNullOrWhiteSpace(l.Arguments):
                    // Unpackaged launches include the program's own path first.
                    foreach (var arg in SplitArguments(l.Arguments).Skip(1))
                    {
                        if (arg.StartsWith("rasternest:", StringComparison.OrdinalIgnoreCase)) HandleUri(new Uri(arg));
                        else if (File.Exists(arg)) OpenPath(arg);
                    }
                    break;
            }
        }
        catch (Exception e) { tray?.Notify("Couldn't open that", e.Message); }
    }

    private static IEnumerable<string> SplitArguments(string line)
    {
        var current = new System.Text.StringBuilder();
        var quoted = false;
        foreach (var c in line)
        {
            if (c == '"') { quoted = !quoted; continue; }
            if (char.IsWhiteSpace(c) && !quoted)
            {
                if (current.Length > 0) { yield return current.ToString(); current.Clear(); }
                continue;
            }
            current.Append(c);
        }
        if (current.Length > 0) yield return current.ToString();
    }

    /// <summary>rasternest://capture, ://fullscreen, ://record, ://text, ://open?path=…</summary>
    private void HandleUri(Uri uri)
    {
        var query = System.Web.HttpUtility.ParseQueryString(uri.Query);
        switch (uri.Host.ToLowerInvariant())
        {
            case "capture": capture?.StartInteractive(); break;
            case "fullscreen": capture?.CaptureFullScreen(); break;
            case "record": capture?.ToggleRecording(); break;
            case "text": capture?.StartInteractive(CaptureCoordinator.Mode.Text); break;
            case "open" when query["path"] is { } path: OpenPath(path); break;
        }
    }

    internal static void OpenPath(string path)
    {
        var library = CaptureLibrary.Shared;
        var item = path.EndsWith("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase)
            ? library.ItemForDocument(path)
            : library.ImportImage(path);
        EditorWindow.Show(item);
    }

    private void RegisterHotKeys()
    {
        if (tray == null || capture == null) return;
        tray.UnregisterHotKeys();
        var s = AppSettings.Shared;
        var failed = new List<string>();
        void Reg(int id, HotKey? key, Action action, string name)
        {
            if (key != null && !tray.RegisterHotKey(id, key, action)) failed.Add($"{name} ({key})");
        }
        Reg(1, s.CaptureHotKey, () => capture.StartInteractive(), "Capture");
        Reg(2, s.FullScreenHotKey, () => capture.CaptureFullScreen(), "Full screen");
        Reg(3, s.RecordHotKey, () => capture.ToggleRecording(), "Record");
        Reg(4, s.TextHotKey, () => capture.StartInteractive(CaptureCoordinator.Mode.Text), "Grab text");
        FailedHotKeys = failed;
        Log.Write($"hotkeys registered; failed: {string.Join(", ", failed)}");
        if (failed.Count > 0)
            tray.Notify("Some shortcuts are taken", $"Another app uses {string.Join(", ", failed)}. Choose different keys in RasterNest Settings.");
    }

    internal static List<string> FailedHotKeys { get; private set; } = [];

    // Actions for the editor's menu bar (the same as the tray menu).
    // From a menu inside RasterNest, its own windows step aside first (they come back afterwards).
    internal void CaptureArea(int delay = 0) => capture?.StartInteractive(delay: delay, hideWindows: true);
    internal void CaptureFullScreen() => capture?.CaptureFullScreen(hideWindows: true);
    internal void ToggleRecording() => capture?.ToggleRecording(hideWindows: true);
    internal void GrabText() => capture?.StartInteractive(CaptureCoordinator.Mode.Text, hideWindows: true);
    internal bool IsRecording => capture?.IsRecording == true;
    internal static void OpenUrl(string url) => Launch(url);

    private IReadOnlyList<TrayIcon.MenuItem> BuildMenu()
    {
        var s = AppSettings.Shared;
        var c = capture!;
        var library = CaptureLibrary.Shared;
        library.Reload();
        var recent = library.Items.Take(8).Select(i => new TrayIcon.MenuItem(i.Name, () => EditorWindow.Show(i))).ToList();
        if (recent.Count == 0) recent.Add(new TrayIcon.MenuItem("No captures yet", Enabled: false));
        recent.Add(TrayIcon.MenuItem.Separator);
        recent.Add(new TrayIcon.MenuItem("Open Captures Folder", () =>
        {
            Directory.CreateDirectory(library.Folder);
            System.Diagnostics.Process.Start("explorer.exe", $"\"{library.Folder}\"");
        }));

        return
        [
            new("Capture Area or Window", () => CaptureArea(), Shortcut: s.CaptureHotKey?.ToString()),
            new("Capture Full Screen", CaptureFullScreen, Shortcut: s.FullScreenHotKey?.ToString()),
            new(c.IsRecording ? "Stop Recording" : "Record Screen", ToggleRecording, Shortcut: s.RecordHotKey?.ToString()),
            new("Grab Text", GrabText, Shortcut: s.TextHotKey?.ToString()),
            new("Capture After Delay", Children:
            [
                new("3 seconds", () => CaptureArea(3)),
                new("5 seconds", () => CaptureArea(5)),
                new("10 seconds", () => CaptureArea(10)),
            ]),
            TrayIcon.MenuItem.Separator,
            new("New from Clipboard", NewFromClipboard),
            new("Open…", OpenFile),
            new("Recent Captures", Children: recent),
            TrayIcon.MenuItem.Separator,
            new("Settings…", SettingsWindow.ShowShared),
            new("About RasterNest", () => Launch("https://rasternest.app")),
            new("Support RasterNest…", () => Launch("https://rasternest.app/#support")),
            new("Quit RasterNest", Quit),
        ];
    }

    private static void Launch(string url) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });

    internal async void NewFromClipboard()
    {
        try
        {
            var view = global::Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (!view.Contains(global::Windows.ApplicationModel.DataTransfer.StandardDataFormats.Bitmap))
            {
                tray?.Notify("Nothing to open", "The clipboard doesn't hold a picture.");
                return;
            }
            using var stream = await (await view.GetBitmapAsync()).OpenReadAsync();
            var bytes = new byte[stream.Size];
            using (var reader = new global::Windows.Storage.Streams.DataReader(stream))
            {
                await reader.LoadAsync((uint)stream.Size);
                reader.ReadBytes(bytes);
            }
            var decoded = RasterNest.Render.ImageCodec.Decode(bytes) ?? throw new InvalidDataException("That picture couldn't be read.");
            using (decoded.Bitmap) EditorWindow.Show(CaptureLibrary.Shared.AddCapture(decoded.Bitmap, decoded.Scale, name: "From Clipboard " + CaptureNaming.TimestampedName()[11..]));
        }
        catch (Exception e) { tray?.Notify("Couldn't open the clipboard picture", e.Message); }
    }

    internal async void OpenFile()
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        foreach (var ext in new[] { ".rasternest", ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, tray!.Handle);
        var file = await picker.PickSingleFileAsync();
        if (file != null) OpenPath(file.Path);
    }

    internal async void Quit()
    {
        if (capture?.IsRecording == true) await capture.StopRecording();
        tray?.Dispose();
        Exit();
    }
}
