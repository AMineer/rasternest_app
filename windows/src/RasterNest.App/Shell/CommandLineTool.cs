using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace RasterNest.App.Shell;

/// <summary>
/// The Windows version of the Mac's "Install Command Line Tool…": puts rnest.exe in
/// %LOCALAPPDATA%\Programs\RasterNest and on your PATH. Also connects RasterNest's MCP server to Claude.
/// </summary>
internal static class CommandLineTool
{
    public const string ReleasesBase = "https://github.com/AMineer/rasternest_app/releases/latest/download";
    public const string ClaudeCodeCommand = "claude mcp add --scope user rasternest -- rnest mcp";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "RasterNest");

    /// <summary>rnest.exe on the PATH (winget or our own install), or in our install folder.</summary>
    public static string? Find()
    {
        var mine = Path.Combine(InstallDir, "rnest.exe");
        if (File.Exists(mine)) return mine;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(Environment.ExpandEnvironmentVariables(dir.Trim()), "rnest.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch { /* odd PATH entry */ }
        }
        // winget puts portable command aliases here.
        var links = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links", "rnest.exe");
        return File.Exists(links) ? links : null;
    }

    /// <summary>Downloads the latest rnest for this PC's processor and adds its folder to your PATH.</summary>
    public static async Task<string> InstallAsync()
    {
        var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        Directory.CreateDirectory(InstallDir);
        var zip = Path.Combine(Path.GetTempPath(), $"rnest-{Guid.NewGuid():N}.zip");
        try
        {
            using (var http = new HttpClient())
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("RasterNest");
                await using var download = await http.GetStreamAsync($"{ReleasesBase}/rnest-windows-{arch}.zip");
                await using var file = File.Create(zip);
                await download.CopyToAsync(file);
            }
            using var archive = ZipFile.OpenRead(zip);
            var entry = archive.GetEntry("rnest.exe") ?? throw new InvalidDataException("The download didn't contain rnest.exe.");
            var target = Path.Combine(InstallDir, "rnest.exe");
            entry.ExtractToFile(target, overwrite: true);
            AddToUserPath(InstallDir);
            return target;
        }
        finally { try { File.Delete(zip); } catch { } }
    }

    private static void AddToUserPath(string dir)
    {
        using var env = Registry.CurrentUser.OpenSubKey("Environment", writable: true) ?? Registry.CurrentUser.CreateSubKey("Environment");
        var current = env.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        if (current.Split(';').Any(p => string.Equals(p.Trim().TrimEnd('\\'), dir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))) return;
        env.SetValue("Path", current.Length == 0 ? dir : current.TrimEnd(';') + ";" + dir, RegistryValueKind.ExpandString);
        // Tell Explorer so new terminals see the change without signing out.
        SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, IntPtr.Zero, "Environment", 2, 5000, out _);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);

    // MARK: Claude

    /// <summary>Claude Desktop's config files: the classic location and, for the Store version, its private copy.</summary>
    public static List<string> ClaudeDesktopConfigs()
    {
        var found = new List<string>();
        var roaming = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude");
        if (Directory.Exists(roaming)) found.Add(Path.Combine(roaming, "claude_desktop_config.json"));
        var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
        if (Directory.Exists(packages))
            foreach (var pkg in Directory.EnumerateDirectories(packages, "Claude_*"))
            {
                var dir = Path.Combine(pkg, "LocalCache", "Roaming", "Claude");
                if (Directory.Exists(dir)) found.Add(Path.Combine(dir, "claude_desktop_config.json"));
            }
        return found;
    }

    /// <summary>
    /// Adds (or updates) "rasternest" under mcpServers in each Claude Desktop config, keeping everything else.
    /// A copy of the previous file is kept beside it as .bak. Returns the files changed.
    /// </summary>
    public static List<string> AddToClaudeDesktop(string rnestPath)
    {
        var changed = new List<string>();
        foreach (var path in ClaudeDesktopConfigs())
        {
            JsonObject root;
            if (File.Exists(path))
            {
                var text = File.ReadAllText(path);
                root = (string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text) as JsonObject)
                       ?? throw new InvalidDataException($"{path} isn't valid JSON, so it was left alone.");
                File.Copy(path, path + ".bak", overwrite: true);
            }
            else root = [];
            if (root["mcpServers"] is not JsonObject servers) root["mcpServers"] = servers = [];
            servers["rasternest"] = new JsonObject { ["command"] = rnestPath, ["args"] = new JsonArray("mcp") };
            File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            changed.Add(path);
        }
        return changed;
    }
}
