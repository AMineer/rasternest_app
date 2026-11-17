using System.Text.Json;
using System.Text.Json.Serialization;
using RasterNest.App.Shell;
using RasterNest.Core;
using static RasterNest.App.Shell.Win32;

namespace RasterNest.App;

/// <summary>
/// Preferences, kept as JSON in %LOCALAPPDATA%\RasterNest\settings.json. Same options as the Mac app.
/// Shortcuts that are null are turned off.
/// </summary>
public sealed class AppSettings
{
    public static AppSettings Shared { get; } = Load();
    public static event Action? Changed;

    public bool OpenEditor { get; set; } = true;
    public bool CopyToClipboard { get; set; } = true;
    public bool KeepPng { get; set; } = true;
    public string SaveFolder { get; set; } = CaptureNaming.DefaultCaptureFolder();

    // Print Screen is the natural capture key on Windows. If Windows' own Snipping Tool has it,
    // registration fails and Settings shows a warning so you can pick another.
    public HotKey? CaptureHotKey { get; set; } = new(VK_SNAPSHOT, 0);
    public HotKey? FullScreenHotKey { get; set; } = new(VK_SNAPSHOT, MOD_SHIFT);
    public HotKey? RecordHotKey { get; set; } = new(VK_SNAPSHOT, MOD_CONTROL);
    public HotKey? ScrollingHotKey { get; set; } = new(VK_SNAPSHOT, MOD_CONTROL | MOD_SHIFT);
    public HotKey? TextHotKey { get; set; } = new(VK_SNAPSHOT, MOD_CONTROL | MOD_ALT);

    public bool RecordSystemAudio { get; set; }
    public bool RecordMicrophone { get; set; }
    public bool ShowClicks { get; set; } = true;
    public bool AdjustBeforeCapture { get; set; } = true;
    public bool CaptureCursor { get; set; }
    public bool ShowKeystrokes { get; set; }
    public bool ShowAllTyping { get; set; }
    /// <summary>Frame applied to new captures, in points (scaled per capture). Null = no frame.</summary>
    public CanvasEffects? DefaultFrame { get; set; }
    public bool HasOnboarded { get; set; }

    // Editor panel widths (DIPs), remembered when you drag their edges.
    public double StripWidth { get; set; } = 132;
    public double InspectorWidth { get; set; } = 272;
    public double CombineWidth { get; set; } = 260;

    /// <summary>The default frame scaled to a capture's pixel density.</summary>
    public CanvasEffects DefaultEffects(double scale)
    {
        if (DefaultFrame is not { } e) return CanvasEffects.None;
        return e with { Padding = e.Padding * scale, CornerRadius = e.CornerRadius * scale, BorderWidth = e.BorderWidth * scale };
    }

    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RasterNest", "settings.json");

    private static readonly JsonSerializerOptions Json = new(RasterNestJson.Pretty)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Json) ?? new AppSettings();
        }
        catch { /* a damaged file falls back to defaults */ }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch { /* not fatal */ }
        Changed?.Invoke();
    }
}
