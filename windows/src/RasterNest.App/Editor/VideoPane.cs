using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using RasterNest.App.Library;
using RasterNest.Windows;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Media.Core;
using global::Windows.Media.Editing;
using global::Windows.Media.Playback;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;

namespace RasterNest.App.Editor;

/// <summary>
/// Recordings open here instead of the image editor: play them, trim the ends, and export a GIF.
/// A port of the Mac VideoPane.
/// </summary>
internal sealed class VideoPane : Grid
{
    private readonly MediaPlayerElement player = new() { AreTransportControlsEnabled = true, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform };
    private readonly TextBlock trimLabel = new() { Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock status = new() { Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed, Minimum = 0, Maximum = 1 };
    private readonly Func<IntPtr> windowHandle;
    private readonly Action<CaptureLibrary.Item> reopened;
    private CaptureLibrary.Item? item;
    private TimeSpan duration, trimStart, trimEnd;
    private CancellationTokenSource? work;

    public StackPanel Inspector { get; } = new() { Spacing = 10 };

    public VideoPane(Func<IntPtr> windowHandle, Action<CaptureLibrary.Item> reopened)
    {
        this.windowHandle = windowHandle;
        this.reopened = reopened;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Padding = new Thickness(16);
        RowSpacing = 10;
        Children.Add(player);

        var setStart = new Button { Content = "Start here" };
        ToolTipService.SetToolTip(setStart, "Trim everything before the playhead");
        setStart.Click += (_, _) => { trimStart = Clamp(Position, TimeSpan.Zero, trimEnd - TimeSpan.FromMilliseconds(200)); ShowTrim(); };
        var setEnd = new Button { Content = "End here" };
        ToolTipService.SetToolTip(setEnd, "Trim everything after the playhead");
        setEnd.Click += (_, _) => { trimEnd = Clamp(Position, trimStart + TimeSpan.FromMilliseconds(200), duration); ShowTrim(); };
        var reset = new Button { Content = "Reset" };
        reset.Click += (_, _) => { trimStart = TimeSpan.Zero; trimEnd = duration; ShowTrim(); };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { setStart, setEnd, reset, trimLabel } };
        SetRow(row, 1);
        Children.Add(row);
        BuildInspector();
    }

    private TimeSpan Position => player.MediaPlayer?.PlaybackSession.Position ?? TimeSpan.Zero;
    private static TimeSpan Clamp(TimeSpan v, TimeSpan min, TimeSpan max) => v < min ? min : v > max ? max : v;
    private static string Format(TimeSpan t) => $"{(int)t.TotalMinutes}:{t.Seconds:00}.{t.Milliseconds / 100}";

    public async void Load(CaptureLibrary.Item recording)
    {
        Stop();
        item = recording;
        status.Text = "";
        var file = await StorageFile.GetFileFromPathAsync(recording.VideoPath!);
        var clip = await MediaClip.CreateFromFileAsync(file);
        duration = clip.OriginalDuration;
        trimStart = TimeSpan.Zero;
        trimEnd = duration;
        player.Source = MediaSource.CreateFromStorageFile(file);
        ShowTrim();
    }

    /// <summary>Stops playback and releases the file (so it can be replaced or deleted).</summary>
    public void Stop()
    {
        work?.Cancel();
        player.MediaPlayer?.Pause();
        (player.Source as MediaSource)?.Dispose();
        player.Source = null;
    }

    private void ShowTrim() =>
        trimLabel.Text = trimStart == TimeSpan.Zero && trimEnd == duration
            ? $"Length {Format(duration)}"
            : $"Keeping {Format(trimStart)} – {Format(trimEnd)} ({Format(trimEnd - trimStart)})";

    private void BuildInspector()
    {
        Inspector.Children.Add(new TextBlock { Text = "Recording", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });

        var width = new ComboBox { Header = "GIF width", ItemsSource = new[] { "480 px", "640 px", "800 px", "1024 px", "Full size" }, SelectedIndex = 2, MinWidth = 160 };
        var fps = new ComboBox { Header = "GIF frame rate", ItemsSource = new[] { "8 fps", "12 fps", "15 fps", "20 fps" }, SelectedIndex = 1, MinWidth = 160 };
        Inspector.Children.Add(width);
        Inspector.Children.Add(fps);

        var gif = new Button { Content = "Export GIF…", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        gif.Click += async (_, _) =>
        {
            if (item?.VideoPath is not { } video) return;
            var picker = new FileSavePicker { SuggestedFileName = item.Name, SuggestedStartLocation = PickerLocationId.PicturesLibrary };
            picker.FileTypeChoices.Add("GIF", [".gif"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle());
            if (await picker.PickSaveFileAsync() is not { } target) return;
            int[] widths = [480, 640, 800, 1024, 0];
            double[] rates = [8, 12, 15, 20];
            await Run("Making GIF…", async (p, ct) =>
            {
                await GifExport.Convert(video, target.Path, rates[Math.Max(0, fps.SelectedIndex)], widths[Math.Max(0, width.SelectedIndex)],
                                        trimStart, trimEnd, p, ct);
                status.Text = $"Saved {target.Path} ({new FileInfo(target.Path).Length / 1024:N0} KB).";
            });
        };
        Inspector.Children.Add(gif);

        var save = new Button { Content = "Save Trimmed Video" };
        ToolTipService.SetToolTip(save, "Replace the recording with the part between Start and End");
        save.Click += async (_, _) =>
        {
            if (item?.VideoPath is not { } video) return;
            if (trimStart == TimeSpan.Zero && trimEnd == duration) { status.Text = "Set a start or end first (play to a point, then Start here / End here)."; return; }
            await Run("Trimming…", async (p, ct) =>
            {
                var composition = new MediaComposition();
                var clip = await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(video));
                clip.TrimTimeFromStart = trimStart;
                clip.TrimTimeFromEnd = duration - trimEnd;
                composition.Clips.Add(clip);
                var tmpPath = Path.Combine(Path.GetTempPath(), $"rasternest-trim-{Guid.NewGuid():N}.mp4");
                File.WriteAllBytes(tmpPath, []);
                var tmp = await StorageFile.GetFileFromPathAsync(tmpPath);
                var op = composition.RenderToFileAsync(tmp, MediaTrimmingPreference.Precise);
                op.Progress = (_, pct) => p.Report(pct / 100);
                await op.AsTask(ct);
                var current = item;
                Stop();
                File.Copy(tmpPath, video, overwrite: true);
                File.Delete(tmpPath);
                status.Text = "Trimmed.";
                reopened(current);
            });
        };
        Inspector.Children.Add(save);

        var copy = new Button { Content = "Copy File" };
        ToolTipService.SetToolTip(copy, "Copy the video to paste into chat, mail or File Explorer");
        copy.Click += async (_, _) =>
        {
            if (item?.VideoPath is not { } video) return;
            var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            data.SetStorageItems([await StorageFile.GetFileFromPathAsync(video)]);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
            status.Text = "Copied the video file.";
        };
        var reveal = new Button { Content = "Show in File Explorer" };
        reveal.Click += (_, _) => { if (item?.VideoPath is { } v) System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{v}\""); };
        Inspector.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { copy, reveal } });
        Inspector.Children.Add(progress);
        Inspector.Children.Add(status);
    }

    private async Task Run(string what, Func<IProgress<double>, CancellationToken, Task> body)
    {
        work?.Cancel();
        work = new CancellationTokenSource();
        status.Text = what;
        progress.Value = 0;
        progress.Visibility = Visibility.Visible;
        var p = new Progress<double>(v => progress.Value = v);
        try { await body(p, work.Token); }
        catch (OperationCanceledException) { status.Text = "Cancelled."; }
        catch (Exception e) { status.Text = $"Couldn't finish: {e.Message}"; }
        finally { progress.Visibility = Visibility.Collapsed; }
    }
}
