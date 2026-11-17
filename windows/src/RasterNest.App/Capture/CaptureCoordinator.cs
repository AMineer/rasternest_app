using RasterNest.App.Editor;
using RasterNest.App.Library;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;
using SkiaSharp;

namespace RasterNest.App.Capture;

/// <summary>Orchestrates a capture: freeze screens → overlay → crop → deliver. A port of the Mac CaptureCoordinator.</summary>
internal sealed class CaptureCoordinator(Action<string, string> notify)
{
    public enum Mode { Image, Text }

    private bool busy;
    private ScreenRecorder? recorder;
    private string? recordingPath;

    public bool IsRecording => recorder != null;

    /// <summary>All-in-one capture (area, window or display), optionally after a countdown.</summary>
    /// <param name="hideWindows">Hide RasterNest's windows first (captures started from the editor's menus).</param>
    public async void StartInteractive(Mode mode = Mode.Image, int delay = 0, bool hideWindows = false)
    {
        Log.Write($"start interactive {mode} busy={busy}");
        if (busy) return;
        busy = true;
        try
        {
            if (hideWindows) await Shell.WindowHider.HideAsync();
            if (delay > 0) await Countdown(delay);
            else await Task.Delay(150); // let the tray menu fade out of the frozen picture
            var hint = mode == Mode.Text
                ? "Select text to copy  ·  click a window  ·  Esc to cancel"
                : "Drag to capture an area  ·  click a window  ·  Space for full screen  ·  Esc to cancel";
            var overlay = new SelectionOverlay(hint, result => Handle(result, mode));
            current = overlay;
            overlay.Show();
        }
        catch (Exception e)
        {
            busy = false;
            Shell.WindowHider.Restore();
            Log.Write($"capture failed: {e}");
            notify("Couldn't capture", e.Message);
        }
    }

    private SelectionOverlay? current;

    private async void Handle(SelectionOverlay.Result result, Mode mode)
    {
        var overlay = current;
        current = null;
        try
        {
            switch (result)
            {
                case SelectionOverlay.Result.Cancelled:
                    return;
                case SelectionOverlay.Result.Display d:
                {
                    var r = new SelectionOverlay.RectI((int)d.Info.X, (int)d.Info.Y, (int)d.Info.Width, (int)d.Info.Height);
                    using var bmp = overlay!.Crop(r);
                    await Deliver(bmp, d.Info.Scale, mode);
                    break;
                }
                case SelectionOverlay.Result.Region reg:
                {
                    using var bmp = overlay!.Crop(reg.Rect);
                    await Deliver(bmp, overlay.ScaleAt(reg.Rect), mode);
                    break;
                }
                case SelectionOverlay.Result.Window w:
                {
                    // Prefer a clean grab of the whole window; fall back to the frozen pixels.
                    Captured? shot = null;
                    try { shot = ScreenCapture.CaptureWindow(w.Info.Id, AppSettings.Shared.CaptureCursor); } catch { }
                    if (shot != null) using (shot.Bitmap) await Deliver(shot.Bitmap, shot.Scale, mode);
                    else using (var bmp = overlay!.Crop(w.Visible)) await Deliver(bmp, overlay.ScaleAt(w.Visible), mode);
                    break;
                }
            }
        }
        catch (Exception e)
        {
            Log.Write($"capture failed: {e}");
            notify("Couldn't capture", CaptureLibrary.Explain(e, CaptureLibrary.Shared.Folder));
        }
        finally
        {
            overlay?.Dispose();
            busy = false;
            Shell.WindowHider.Restore();
        }
    }

    public async void CaptureFullScreen(bool hideWindows = false)
    {
        if (busy) return;
        busy = true;
        try
        {
            if (hideWindows) await Shell.WindowHider.HideAsync();
            await Task.Delay(150);
            Shell.Win32.GetCursorPos(out var p);
            var displays = ScreenCapture.Displays();
            var index = displays.FindIndex(d => p.X >= d.X && p.X < d.X + d.Width && p.Y >= d.Y && p.Y < d.Y + d.Height);
            var shot = ScreenCapture.CaptureDisplay(Math.Max(0, index), AppSettings.Shared.CaptureCursor);
            using (shot.Bitmap) await Deliver(shot.Bitmap, shot.Scale, Mode.Image);
        }
        catch (Exception e)
        {
            Log.Write($"full-screen capture failed: {e}");
            notify("Couldn't capture", CaptureLibrary.Explain(e, CaptureLibrary.Shared.Folder));
        }
        finally
        {
            busy = false;
            Shell.WindowHider.Restore();
        }
    }

    private async Task Deliver(SKBitmap image, double scale, Mode mode)
    {
        if (mode == Mode.Text)
        {
            var lines = await TextRecognition.AnalyzeAsync(image);
            var text = string.Join("\n", lines.Select(l => l.Text));
            if (text.Length == 0) { notify("No text found", "Try a larger area."); return; }
            RasterNest.Windows.Clipboard.CopyText(text);
            notify("Text copied", $"Copied {lines.Count} line{(lines.Count == 1 ? "" : "s")} of text.");
            return;
        }
        var settings = AppSettings.Shared;
        var item = CaptureLibrary.Shared.AddCapture(image, scale);
        if (settings.CopyToClipboard)
        {
            var defaults = settings.DefaultEffects(scale);
            if (defaults.IsEmpty) RasterNest.Windows.Clipboard.CopyPng(ImageCodec.EncodePng(image, scale));
            else using (var flat = new AnnotationRenderer(scale).Flatten(image, [], defaults)) RasterNest.Windows.Clipboard.CopyImage(flat, scale);
        }
        if (settings.OpenEditor) EditorWindow.Show(item);
        else notify(settings.CopyToClipboard ? "Copied to clipboard" : "Saved", item.Name);
    }

    // MARK: scrolling capture

    /// <summary>Pick the area that scrolls, then scroll; Done stitches everything into one tall image.</summary>
    public async void StartScrolling(bool hideWindows = false, RectD? area = null)
    {
        // Triggering it again while scrolling finishes the capture (like Done).
        if (scrolling != null) { scrolling.Finish(); return; }
        if (busy) return;
        busy = true;
        try
        {
            if (hideWindows) await Shell.WindowHider.HideAsync();
            await Task.Delay(150);
            if (area is { } given)
            {
                // rasternest://scrolling?rect=x,y,w,h skips the overlay.
                var scale = ScreenCapture.Displays().FirstOrDefault(d => given.MidX >= d.X && given.MidX < d.X + d.Width)?.Scale ?? 1;
                await RunScrolling(given, scale);
                return;
            }
            var overlay = new SelectionOverlay("Drag over the part that scrolls, or click a window  ·  Esc to cancel", async result =>
            {
                var o = current;
                current = null;
                try
                {
                    var (rect, scale) = result switch
                    {
                        SelectionOverlay.Result.Region r => (new RectD(r.Rect.X, r.Rect.Y, r.Rect.W, r.Rect.H), o!.ScaleAt(r.Rect)),
                        SelectionOverlay.Result.Window w => (new RectD(w.Visible.X, w.Visible.Y, w.Visible.W, w.Visible.H), o!.ScaleAt(w.Visible)),
                        SelectionOverlay.Result.Display d => (new RectD(d.Info.X, d.Info.Y, d.Info.Width, d.Info.Height), d.Info.Scale),
                        _ => (RectD.Null, 1.0),
                    };
                    o?.Dispose();
                    if (rect.IsNull) { busy = false; Shell.WindowHider.Restore(); return; }
                    await RunScrolling(rect, scale);
                    return;
                }
                catch (Exception e)
                {
                    Log.Write($"scrolling capture failed: {e}");
                    notify("Couldn't finish the scrolling capture", CaptureLibrary.Explain(e, CaptureLibrary.Shared.Folder));
                }
                busy = false;
                Shell.WindowHider.Restore();
            });
            current = overlay;
            overlay.Show();
        }
        catch (Exception e)
        {
            busy = false;
            Shell.WindowHider.Restore();
            notify("Couldn't capture", e.Message);
        }
    }

    private ScrollingCapture? scrolling;

    private async Task RunScrolling(RectD rect, double scale)
    {
        try
        {
            if (rect.Width < 40 || rect.Height < 60) { notify("Pick a larger area", "Choose the part of the window that scrolls."); return; }
            scrolling = new ScrollingCapture(rect, scale);
            using var stitched = await scrolling.RunAsync();
            scrolling = null;
            if (stitched != null) await Deliver(stitched, scale, Mode.Image);
        }
        catch (Exception e)
        {
            Log.Write($"scrolling capture failed: {e}");
            notify("Couldn't finish the scrolling capture", CaptureLibrary.Explain(e, CaptureLibrary.Shared.Folder));
        }
        finally
        {
            scrolling = null;
            busy = false;
            Shell.WindowHider.Restore();
        }
    }

    // MARK: recording

    /// <summary>Pick an area, window or screen, 3-2-1, record. Triggering it again stops.</summary>
    public async void ToggleRecording(bool hideWindows = false)
    {
        if (recorder != null) { await StopRecording(); return; }
        if (busy) return;
        busy = true;
        try
        {
            // Hidden for the whole recording; StopRecording brings them back.
            if (hideWindows) await Shell.WindowHider.HideAsync();
            await Task.Delay(150);
            var overlay = new SelectionOverlay("Drag an area to record, click a window, or press Space for the whole screen  ·  Esc to cancel",
                                               async result =>
                                               {
                                                   var o = current;
                                                   current = null;
                                                   o?.Dispose();
                                                   await BeginRecording(result);
                                               });
            current = overlay;
            overlay.Show();
        }
        catch (Exception e)
        {
            busy = false;
            Shell.WindowHider.Restore();
            notify("Couldn't record", e.Message);
        }
    }

    private async Task BeginRecording(SelectionOverlay.Result result)
    {
        try
        {
            RecordTarget? target = result switch
            {
                SelectionOverlay.Result.Region r when r.Rect.W >= 32 && r.Rect.H >= 32 => new RecordTarget.Area(new RectD(r.Rect.X, r.Rect.Y, r.Rect.W, r.Rect.H)),
                SelectionOverlay.Result.Window w => new RecordTarget.Window(w.Info.Id),
                SelectionOverlay.Result.Display d => new RecordTarget.Display(d.Info.Index),
                _ => null,
            };
            if (target == null)
            {
                if (result is SelectionOverlay.Result.Region) notify("Pick a larger area", "Recordings need at least 32 × 32 pixels.");
                busy = false;
                Shell.WindowHider.Restore();
                return;
            }
            await Countdown(3);
            recordingPath = Path.Combine(Path.GetTempPath(), $"RasterNest-{Guid.NewGuid():N}.mp4");
            recorder = new ScreenRecorder(target, new RecorderOptions(30, true));
            await recorder.StartAsync(recordingPath);
            RecordingChanged?.Invoke();
            // Stop button on screen (left out of the recording itself); the tray and shortcut still work too.
            bar = new CaptureBar("Recording", "Stop", () => _ = StopRecording());
            bar.Show();
        }
        catch (Exception e)
        {
            recorder = null;
            busy = false;
            Shell.WindowHider.Restore();
            notify("Couldn't record", e.Message);
        }
    }

    public event Action? RecordingChanged;
    private CaptureBar? bar;

    public async Task StopRecording()
    {
        if (recorder is not { } r) return;
        recorder = null;
        bar?.Close();
        bar = null;
        try
        {
            await r.StopAsync();
            await r.DisposeAsync();
            var item = CaptureLibrary.Shared.AddRecording(recordingPath!);
            // Opens in the editor's video pane (play, trim, export GIF).
            EditorWindow.Show(item);
        }
        catch (Exception e) { notify("Couldn't finish the recording", e.Message); }
        finally
        {
            busy = false;
            Shell.WindowHider.Restore();
            RecordingChanged?.Invoke();
        }
    }

    /// <summary>3, 2, 1 in a small topmost window.</summary>
    private static async Task Countdown(int seconds)
    {
        var window = new CountdownWindow();
        for (var i = seconds; i > 0; i--)
        {
            window.Show(i);
            await Task.Delay(1000);
        }
        window.Close();
        await Task.Delay(100);
    }
}
