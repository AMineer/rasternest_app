using System.Text;

namespace RasterNest.Core;

/// <summary>
/// A rebuildable documentation guide: a list of steps, each a capture plus markup.
/// <c>rnest guide run</c> re-captures every step, so when the UI changes the screenshots regenerate.
/// Same JSON as the Mac/Linux version.
/// </summary>
public sealed record Guide
{
    public string Title { get; init; } = "";
    /// <summary>Folder for the images, relative to the guide file. Default: &lt;guide name&gt;-images.</summary>
    public string? Output { get; init; }
    /// <summary>Frame for every step unless the step sets its own: none or docs.</summary>
    public string? Frame { get; init; }
    /// <summary>Markdown file to write (relative to the guide file). Default: &lt;guide name&gt;.md. "" skips it.</summary>
    public string? Markdown { get; init; }
    /// <summary>Optional PDF of all steps (relative to the guide file).</summary>
    public string? Pdf { get; init; }
    public List<GuideStep> Steps { get; init; } = [];

    /// <summary>File-name stem for step index (0-based): 01-open-settings.</summary>
    public string Stem(int index)
    {
        var n = (index + 1).ToString("00");
        var name = Steps[index].Name?.Trim();
        if (string.IsNullOrEmpty(name)) return n;
        var slug = new string(name.ToLowerInvariant().Select(c => char.IsLetter(c) || char.IsNumber(c) ? c : '-').ToArray());
        var collapsed = string.Join('-', slug.Split('-', StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length == 0 ? n : $"{n}-{collapsed}";
    }

    /// <summary>Markdown for the guide, with image paths relative to the markdown file.</summary>
    public string ToMarkdown(IReadOnlyList<string> imagePaths)
    {
        var md = new StringBuilder($"# {Title}\n");
        for (var i = 0; i < Steps.Count; i++)
        {
            var step = Steps[i];
            md.Append($"\n## Step {i + 1}");
            if (!string.IsNullOrEmpty(step.Caption)) md.Append($"\n\n{step.Caption}");
            if (i < imagePaths.Count)
            {
                var alt = (step.Caption ?? $"Step {i + 1}").Replace("]", "");
                md.Append($"\n\n![{alt}]({imagePaths[i]})");
            }
            md.Append('\n');
        }
        return md.ToString();
    }

    public static Guide Decoded(string json) => RasterNestJson.Deserialize<Guide>(json);

    /// <summary>A starter guide written by <c>rnest guide init</c> (Windows flavor).</summary>
    public static Guide Example => new()
    {
        Title = "Example guide",
        Frame = "docs",
        Steps =
        [
            new GuideStep
            {
                Name = "desktop",
                Caption = "This is the whole screen. Replace `capture` with a window, e.g. { \"app\": \"msedge\" }.",
                Capture = new CaptureSpec { Fullscreen = true },
                Annotations = [new SpecItem { Type = "redact", Pattern = "email" }],
            },
            new GuideStep
            {
                Name = "explorer",
                Caption = "File Explorer, with step 1 on Home.",
                Before = "explorer.exe",
                Wait = 2,
                Capture = new CaptureSpec { App = "explorer" },
                Annotations = [new SpecItem { Type = "step", At = new SpecAnchor { Text = "Home" }, Label = "Start here" }],
            },
        ],
    };
}

public sealed record GuideStep
{
    /// <summary>Short identifier used in file names. Default: step number.</summary>
    public string? Name { get; init; }
    public string? Caption { get; init; }
    /// <summary>Shell command run before capturing (e.g. open an app or URL).</summary>
    public string? Before { get; init; }
    /// <summary>Seconds to wait after before and before capturing.</summary>
    public double? Wait { get; init; }
    public CaptureSpec Capture { get; init; } = new();
    public string? Frame { get; init; }
    public List<SpecItem>? Annotations { get; init; }
}

/// <summary>What to capture. Exactly one field is used, in this order: file, window/app, rect, display/fullscreen.</summary>
public sealed record CaptureSpec
{
    /// <summary>An existing image to annotate instead of capturing (relative to the guide file).</summary>
    public string? File { get; init; }
    /// <summary>Front-most window whose app name or title contains this text.</summary>
    public string? Window { get; init; }
    /// <summary>Front-most window of an app with this name (process name on Windows, e.g. "msedge").</summary>
    public string? App { get; init; }
    /// <summary>Narrows app to a window whose title contains this.</summary>
    public string? Title { get; init; }
    /// <summary>[x, y, width, height] in screen points, origin top-left of the main display.</summary>
    public List<double>? Rect { get; init; }
    public bool? Fullscreen { get; init; }
    public int? Display { get; init; }
    /// <summary>Include the mouse pointer.</summary>
    public bool? Cursor { get; init; }
}
