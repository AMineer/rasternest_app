using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using RasterNest.App.Library;
using RasterNest.Core;
using RasterNest.Render;
using RasterNest.Windows;
using SkiaSharp;
using SkiaSharp.Views.Windows;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using Geometry = RasterNest.Core.Geometry;

namespace RasterNest.App.Editor;

/// <summary>
/// The editor: capture strip, tools, canvas and inspector. One window shows one capture at a time; picking another
/// in the strip saves the current one first (as on the Mac).
/// </summary>
public sealed partial class EditorWindow : Window
{
    private static EditorWindow? shared;
    internal static EditorWindow? Current => shared;

    private EditorModel? model;
    private CaptureLibrary.Item? item;
    private AnnotationRenderer renderer = new();
    private double zoom = 1;
    private bool fitOnNextLayout = true;
    private bool loadingStrip;

    private enum DragKind { None, Creating, Moving, Handle, Cropping }
    private DragKind drag;
    private Guid dragId;
    private PointD dragOrigin;
    private Annotation? dragOriginal;
    private int dragHandle;
    private EditorModel.Snapshot? dragStart;

    private TextBox? textBox;
    private Guid? editingId;
    private EditorModel.Snapshot? editingSnapshot;
    private bool editingIsNew;

    private readonly Dictionary<Tool, ToggleButton> toolButtons = [];

    /// <summary>Opens (or brings forward) the editor showing item.</summary>
    public static void Show(CaptureLibrary.Item item)
    {
        if (shared == null)
        {
            shared = new EditorWindow();
            shared.Closed += (_, _) => shared = null;
        }
        shared.Open(item);
        shared.Activate();
        Shell.Win32.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(shared));
    }

    public EditorWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = false;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "rasternest.ico"));
        // Start at 1400 × 900 (in DIPs), but never bigger than the screen we open on.
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var dpi = Shell.Win32.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        int w = Math.Min((int)(1400 * dpi), area.Width), h = Math.Min((int)(900 * dpi), area.Height);
        AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
        Root.PreviewKeyDown += Root_PreviewKeyDown;
        BuildToolBar();
        BuildMenuBar();
        SetUpPanelSizes();
        CaptureLibrary.Shared.Changed += RefreshStrip;
        Closed += (_, _) =>
        {
            SaveIfNeeded();
            CaptureLibrary.Shared.Changed -= RefreshStrip;
            model?.Dispose();
        };
        RefreshStrip();
    }

    // MARK: menu bar

    /// <summary>File, Edit, View, Window and Help, mirroring the Mac app's menu bar.</summary>
    private void BuildMenuBar()
    {
        var app = App.CurrentApp;
        MenuBarItem Menu(string title, params MenuFlyoutItemBase[] items)
        {
            var m = new MenuBarItem { Title = title };
            foreach (var i in items) m.Items.Add(i);
            return m;
        }
        // Shortcut text only: the keys themselves are handled by the editor's key handler.
        MenuFlyoutItem Item(string text, Action action, string? keys = null, string? glyph = null)
        {
            var i = new MenuFlyoutItem { Text = text };
            if (keys != null) i.KeyboardAcceleratorTextOverride = keys;
            if (glyph != null) i.Icon = new FontIcon { Glyph = glyph };
            i.Click += (_, _) => action();
            return i;
        }
        MenuFlyoutSeparator Sep() => new();
        string? Hot(Shell.HotKey? k) => k?.ToString();
        var s = AppSettings.Shared;

        var delay = new MenuFlyoutSubItem { Text = "Capture After Delay" };
        foreach (var sec in new[] { 3, 5, 10 }) delay.Items.Add(Item($"{sec} seconds", () => app?.CaptureArea(sec)));
        var record = Item("Record Screen", () => app?.ToggleRecording(), Hot(s.RecordHotKey), "\uE7C8");

        var stripToggle = new ToggleMenuFlyoutItem { Text = "Captures Strip", IsChecked = true };
        stripToggle.Click += (_, _) => StripColumn.Width = new GridLength(stripToggle.IsChecked ? s.StripWidth : 0);
        var combineToggle = new ToggleMenuFlyoutItem { Text = "Combine Pane" };
        combineToggle.Click += (_, _) => SetCombineVisible(combineToggle.IsChecked);

        var view = Menu("View",
            Item("Zoom In", () => SetZoom(zoom * 1.25), "Ctrl+Plus"),
            Item("Zoom Out", () => SetZoom(zoom / 1.25), "Ctrl+Minus"),
            Item("Actual Size", () => SetZoom(1), "Ctrl+1"),
            Item("Zoom to Fit", () => SetZoom(FitZoom()), "Ctrl+0"),
            Sep(), stripToggle, combineToggle);

        var fileMenu = Menu("File",
            Item("Capture Area or Window", () => app?.CaptureArea(), Hot(s.CaptureHotKey), "\uF7ED"),
            Item("Capture Full Screen", () => app?.CaptureFullScreen(), Hot(s.FullScreenHotKey), "\uE740"),
            Item("Scrolling Capture", () => app?.ScrollingCapture(), Hot(s.ScrollingHotKey), "\uEC8F"),
            record,
            Item("Grab Text", () => app?.GrabText(), Hot(s.TextHotKey), "\uE8D2"),
            delay,
            Sep(),
            Item("New from Clipboard", () => app?.NewFromClipboard(), "Ctrl+N"),
            Item("Open…", () => app?.OpenFile(), "Ctrl+O", "\uE8E5"),
            Sep(),
            Item("Save", () => { SaveIfNeeded(); UpdateChrome(); }, "Ctrl+S", "\uE74E"),
            Item("Export…", () => Export_Click(this, new RoutedEventArgs()), "Ctrl+Shift+S", "\uEDE1"),
            Item("Show in File Explorer", () => { if (item != null) System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.SharePath}\""); }),
            Sep(),
            Item("Close", Close, "Ctrl+W"),
            Item("Quit RasterNest", () => app?.Quit()));
        // The record item's label follows the recording state.
        fileMenu.Items[0].Loaded += (_, _) => record.Text = app?.IsRecording == true ? "Stop Recording" : "Record Screen";

        MainMenu.Items.Add(fileMenu);
        MainMenu.Items.Add(Menu("Edit",
            Item("Undo", () => { FinishEditing(); model?.Undo(); }, "Ctrl+Z", "\uE7A7"),
            Item("Redo", () => { FinishEditing(); model?.Redo(); }, "Ctrl+Y", "\uE7A6"),
            Sep(),
            Item("Copy Image", CopyImage, "Ctrl+C", "\uE8C8"),
            Item("Copy Text", CopyText),
            Item("Paste as Layer", PasteImage, "Ctrl+V", "\uE77F"),
            Sep(),
            Item("Duplicate", () => model?.DuplicateSelected(), "Ctrl+D"),
            Item("Bring to Front", () => model?.BringSelectedToFront()),
            Item("Send to Back", () => model?.SendSelectedToBack()),
            Item("Delete", () => model?.DeleteSelected(), "Del", "\uE74D"),
            Sep(),
            Item("Crop", () => { if (model != null) model.Tool = Tool.Crop; }, "C", "\uE7A8"),
            Item("Fit Canvas to Content", () => { model?.FitCanvasToContent(); LayoutCanvas(); })));
        MainMenu.Items.Add(view);
        MainMenu.Items.Add(Menu("Window",
            Item("Settings…", SettingsWindow.ShowShared, "Ctrl+,", "\uE713"),
            Item("Open Captures Folder", () =>
            {
                Directory.CreateDirectory(CaptureLibrary.Shared.Folder);
                System.Diagnostics.Process.Start("explorer.exe", $"\"{CaptureLibrary.Shared.Folder}\"");
            }),
            Item("Minimize", () => (AppWindow.Presenter as Microsoft.UI.Windowing.OverlappedPresenter)?.Minimize())));
        MainMenu.Items.Add(Menu("Help",
            Item("RasterNest Website", () => App.OpenUrl("https://rasternest.app")),
            Item("Command Line and AI Agents", () => App.OpenUrl("https://rasternest.app/#agents")),
            Item("Report a Problem", () => App.OpenUrl("https://github.com/AMineer/rasternest_app/issues")),
            Item("Install Command Line Tool…", SettingsWindow.ShowShared),
            Item("Set Up Claude…", SettingsWindow.ShowShared),
            Sep(),
            Item("Support RasterNest…", () => App.OpenUrl("https://rasternest.app/#support")),
            Item($"About RasterNest {RasterNestInfo.Version}", () => App.OpenUrl("https://rasternest.app"))));
    }

    // MARK: panel sizes

    private double ThumbnailHeight => Math.Clamp((StripColumn.Width.Value - 28) * 0.6, 40, 260);

    /// <summary>Drag the edges of the strip, the Combine pane and the inspector to resize them (remembered).</summary>
    private void SetUpPanelSizes()
    {
        var s = AppSettings.Shared;
        StripColumn.Width = new GridLength(s.StripWidth);
        InspectorColumn.Width = new GridLength(s.InspectorWidth);
        void Add(Splitter splitter, int column)
        {
            Grid.SetColumn(splitter, column);
            Panels.Children.Add(splitter);
        }
        Add(new Splitter(HorizontalAlignment.Right, () => StripColumn.Width.Value, w =>
        {
            StripColumn.Width = new GridLength(w);
            s.StripWidth = w;
            foreach (var row in Strip.Items.OfType<ListViewItem>())
                if (row.Content is StackPanel { Children.Count: > 0 } p && p.Children[0] is Image img) img.Height = ThumbnailHeight;
        }, 90, 420, 132, s.Save), 0);
        Add(new Splitter(HorizontalAlignment.Right, () => s.CombineWidth, w =>
        {
            s.CombineWidth = w;
            if (CombineHost.Visibility == Visibility.Visible) CombineColumn.Width = new GridLength(w);
        }, 220, 520, 260, s.Save), 1);
        Add(new Splitter(HorizontalAlignment.Left, () => InspectorColumn.Width.Value, w =>
        {
            InspectorColumn.Width = new GridLength(w);
            s.InspectorWidth = w;
        }, 220, 480, 272, s.Save), 3);
    }

    // MARK: opening and saving

    private void Open(CaptureLibrary.Item next)
    {
        if (item?.Id == next.Id && model != null) return;
        SaveIfNeeded();
        FinishEditing();
        CaptureLibrary.Item target = next;
        if (target.IsVideo) { OpenVideo(target); return; }
        ShowVideo(false);
        (SKBitmap Image, double Scale, List<Annotation> Annotations, CanvasEffects Effects) loaded;
        try { loaded = CaptureLibrary.Shared.Load(target); }
        catch (Exception e)
        {
            Status.Text = $"Couldn't open {target.Name}: {e.Message}";
            return;
        }
        model?.Dispose();
        using (loaded.Image)
            model = new EditorModel(SKImage.FromBitmap(loaded.Image.Copy()), loaded.Scale, loaded.Annotations, loaded.Effects);
        item = target;
        renderer = new AnnotationRenderer(model.PixelScale);
        model.Changed += () => { Canvas.Invalidate(); UpdateChrome(); };
        model.InspectorChanged += BuildInspector;
        // Pictures laid out by Combine (or dropped in) are for arranging: start with Select so a click picks one up.
        if (model.Annotations.Any(a => a.Kind == AnnotationKind.Image)) model.Tool = Tool.Select;
        Title = $"{target.Name} — RasterNest";
        fitOnNextLayout = true;
        LayoutCanvas();
        SelectInStrip(target.Id);
        BuildInspector();
        UpdateChrome();
    }

    // MARK: recordings

    private VideoPane? videoPane;

    private void OpenVideo(CaptureLibrary.Item recording)
    {
        model?.Dispose();
        model = null;
        item = recording;
        videoPane ??= new VideoPane(() => WinRT.Interop.WindowNative.GetWindowHandle(this), r => { item = null; Open(r); });
        ShowVideo(true);
        videoPane.Load(recording);
        Title = $"{recording.Name} — RasterNest";
        SelectInStrip(recording.Id);
        BuildInspector();
        Status.Text = "Recording · play it, set Start here / End here to trim, then Export GIF or Save Trimmed Video.";
    }

    private void ShowVideo(bool visible)
    {
        if (!visible) videoPane?.Stop();
        if (visible && VideoHost.Child == null) VideoHost.Child = videoPane;
        VideoHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        Scroller.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        ToolBar.IsHitTestVisible = !visible;
        ToolBar.Opacity = visible ? 0.4 : 1;
    }

    private void SaveIfNeeded()
    {
        if (model is not { IsDirty: true } || item == null) return;
        FinishEditing();
        try
        {
            using var rendered = model.Flattened();
            CaptureLibrary.Shared.Save(item, model.MakeDocument(), rendered);
            model.MarkSaved();
        }
        catch (Exception e)
        {
            Status.Text = $"Couldn't save: {CaptureLibrary.Explain(e, Path.GetDirectoryName(item.DocumentPath) ?? "")}";
            Log.Write($"save failed: {e}");
        }
    }

    private void UpdateChrome()
    {
        if (model == null) return;
        UndoButton.IsEnabled = model.CanUndo;
        RedoButton.IsEnabled = model.CanRedo;
        ZoomButton.Content = $"{Math.Round(zoom * 100)}%";
        var tip = model.Tool switch
        {
            Tool.Crop => "Drag to choose the area to keep, then press Enter.",
            Tool.Text => "Click to add text. Shift+Enter adds a line.",
            Tool.Step => "Click to add the next number.",
            _ => "Drag to draw. Shift keeps lines straight and boxes square.",
        };
        Status.Text = $"{model.Image.Width} × {model.Image.Height} px   ·   {(model.IsDirty ? "Edited" : "Saved")}   ·   {tip}";
        foreach (var (t, b) in toolButtons) b.IsChecked = t == model.Tool;
    }

    // MARK: toolbar

    private void BuildToolBar()
    {
        foreach (var t in Tools.All)
        {
            var b = new ToggleButton
            {
                Content = new FontIcon { Glyph = t.Glyph(), FontSize = 16 },
                Padding = new Thickness(8, 6, 8, 6),
                Tag = t,
            };
            ToolTipService.SetToolTip(b, $"{t.Title()} ({t.Shortcut()})");
            b.Click += (_, _) => { if (model != null) { FinishEditing(); model.Tool = t; } };
            toolButtons[t] = b;
            ToolBar.Children.Add(b);
        }
    }

    private void Undo_Click(object sender, RoutedEventArgs e) { FinishEditing(); model?.Undo(); }
    private void Redo_Click(object sender, RoutedEventArgs e) { FinishEditing(); model?.Redo(); }

    // MARK: zoom and layout

    private double RasterScale => Content?.XamlRoot?.RasterizationScale ?? 1;
    private double Padding => model?.Effects.Padding ?? 0;

    private void LayoutCanvas()
    {
        if (model == null) return;
        if (fitOnNextLayout && Scroller.ActualWidth > 0)
        {
            fitOnNextLayout = false;
            zoom = FitZoom();
        }
        var w = model.Image.Width + Padding * 2;
        var h = model.Image.Height + Padding * 2;
        // Keep the drawing surface under ~60 megapixels.
        zoom = Math.Min(zoom, Math.Sqrt(60_000_000 / (w * h)));
        Canvas.Width = w * zoom / RasterScale;
        Canvas.Height = h * zoom / RasterScale;
        TextLayer.Width = Canvas.Width;
        TextLayer.Height = Canvas.Height;
        Canvas.Invalidate();
        LayoutTextBox();
        UpdateChrome();
    }

    private double FitZoom()
    {
        if (model == null) return 1;
        var availW = Math.Max(100, (Scroller.ActualWidth - 48) * RasterScale);
        var availH = Math.Max(100, (Scroller.ActualHeight - 48) * RasterScale);
        return Math.Min(1, Math.Min(availW / (model.Image.Width + Padding * 2), availH / (model.Image.Height + Padding * 2)));
    }

    private void SetZoom(double z) { zoom = Math.Clamp(z, 0.1, 8); LayoutCanvas(); }
    private void ZoomFit_Click(object sender, RoutedEventArgs e) => SetZoom(FitZoom());
    private void ZoomActual_Click(object sender, RoutedEventArgs e) => SetZoom(1);
    private void ZoomIn_Click(object sender, RoutedEventArgs e) => SetZoom(zoom * 1.25);
    private void ZoomOut_Click(object sender, RoutedEventArgs e) => SetZoom(zoom / 1.25);
    private void Scroller_SizeChanged(object sender, SizeChangedEventArgs e) { if (fitOnNextLayout) LayoutCanvas(); }

    private void Scroller_PointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        if (!ctrl) return;
        var delta = e.GetCurrentPoint(Scroller).Properties.MouseWheelDelta;
        SetZoom(delta > 0 ? zoom * 1.1 : zoom / 1.1);
        e.Handled = true;
    }

    // MARK: drawing

    private void Canvas_PaintSurface(object? sender, SKPaintSurfaceEventArgs e)
    {
        var c = e.Surface.Canvas;
        c.Clear(SKColors.Transparent);
        if (model == null) return;
        var k = (float)(e.Info.Width / (model.Image.Width + Padding * 2));
        c.Scale(k);
        c.Translate((float)Padding, (float)Padding);
        renderer.Render(c, model.Image, model.Annotations, model.Effects, editingId);
        var m = k; // device pixels per image pixel
        if (model.Tool == Tool.Crop) DrawCropOverlay(c, m);
        else if (model.Selected is { } sel && sel.Id != editingId) DrawSelection(c, sel, m);
    }

    private static readonly SKColor Accent = new(0x7C, 0x3A, 0xED);

    private static void DrawSelection(SKCanvas c, Annotation a, float m)
    {
        using var stroke = new SKPaint { IsAntialias = true, IsStroke = true, StrokeWidth = 1 / m, Color = Accent };
        if (a.Kind is not (AnnotationKind.Arrow or AnnotationKind.Line))
        {
            using var dashed = new SKPaint { IsAntialias = true, IsStroke = true, StrokeWidth = 1 / m, Color = Accent,
                                             PathEffect = SKPathEffect.CreateDash([4 / m, 3 / m], 0) };
            c.DrawRect(a.Bounds.Inset(-3 / m, -3 / m).ToSK(), dashed);
        }
        var size = 9 / m;
        using var fill = new SKPaint { Color = SKColors.White };
        foreach (var h in a.Handles)
        {
            var r = SKRect.Create((float)h.X - size / 2, (float)h.Y - size / 2, size, size);
            c.DrawRect(r, fill);
            c.DrawRect(r, stroke);
        }
    }

    private void DrawCropOverlay(SKCanvas c, float m)
    {
        if (model?.CropRect is not { } r) return;
        using var path = new SKPath { FillType = SKPathFillType.EvenOdd };
        path.AddRect(model.ImageBounds.ToSK());
        path.AddRect(r.ToSK());
        using (var dim = new SKPaint { Color = new SKColor(0, 0, 0, 140) }) c.DrawPath(path, dim);
        using (var white = new SKPaint { IsAntialias = true, IsStroke = true, StrokeWidth = 1.5f / m, Color = SKColors.White }) c.DrawRect(r.ToSK(), white);
        using var guide = new SKPaint { IsStroke = true, StrokeWidth = 1 / m, Color = new SKColor(255, 255, 255, 90) };
        for (var i = 1; i <= 2; i++)
        {
            float x = (float)(r.MinX + r.Width * i / 3), y = (float)(r.MinY + r.Height * i / 3);
            c.DrawLine(x, (float)r.MinY, x, (float)r.MaxY, guide);
            c.DrawLine((float)r.MinX, y, (float)r.MaxX, y, guide);
        }
    }

    // MARK: pointer

    private PointD ImagePoint(PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(Canvas).Position;
        return new PointD(p.X * RasterScale / zoom - Padding, p.Y * RasterScale / zoom - Padding);
    }

    private double HitTolerance => 6 * RasterScale / zoom;

    private Annotation? Hit(PointD p) => model?.Annotations.AsEnumerable().Reverse().FirstOrDefault(a => a.HitTest(p, HitTolerance));

    private int? HandleIndex(PointD p, Annotation a)
    {
        var reach = 8 * RasterScale / zoom;
        for (var i = 0; i < a.Handles.Count; i++) if (Geometry.Distance(a.Handles[i], p) <= reach) return i;
        return null;
    }

    private void StartMove(Annotation a, PointD p)
    {
        dragStart = model!.Current;
        // A picture you pick up goes on top, so it can be laid over another one.
        if (a.Kind == AnnotationKind.Image) model.RaiseSilently(a.Id);
        drag = DragKind.Moving;
        dragId = a.Id;
        dragOrigin = p;
        dragOriginal = a.Clone();
    }

    private void Canvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (model == null) return;
        var point = e.GetCurrentPoint(Canvas);
        if (!point.Properties.IsLeftButtonPressed) return;
        var wasEditing = editingId != null;
        FinishEditing();
        Scroller.Focus(FocusState.Pointer);
        Canvas.CapturePointer(e.Pointer);
        var p = ImagePoint(e);

        if (model.Tool == Tool.Crop)
        {
            drag = DragKind.Cropping;
            dragOrigin = p;
            model.CropRect = null;
            return;
        }
        if (model.Selected is { } selected && HandleIndex(p, selected) is { } hi)
        {
            dragStart = model.Current;
            if (selected.Kind == AnnotationKind.Image) model.RaiseSilently(selected.Id);
            drag = DragKind.Handle;
            dragId = selected.Id;
            dragHandle = hi;
            return;
        }
        switch (model.Tool)
        {
            case Tool.Select:
                if (Hit(p) is { } h) { model.Select(h.Id); StartMove(h, p); }
                else { model.Select(null); drag = DragKind.None; }
                break;
            case Tool.Text:
                if (wasEditing) return; // the first click outside just commits
                if (Hit(p) is { Kind: AnnotationKind.Text } t) { model.Select(t.Id); BeginEditing(t.Id, false); }
                else CreateText(p);
                break;
            case Tool.Step:
            {
                if (Hit(p) is { Kind: AnnotationKind.Step } s) { model.Select(s.Id); StartMove(s, p); return; }
                var pre = model.Current;
                var step = new Annotation(AnnotationKind.Step, p, number: model.NextStepNumber, style: model.StyleFor(Tool.Step));
                model.Insert(step);
                model.Select(step.Id);
                model.RegisterUndo(pre);
                StartMove(step, p);
                break;
            }
            default:
            {
                if (model.Selected is { } sel && sel.HitTest(p, HitTolerance)) { StartMove(sel, p); return; }
                if (model.Tool.Kind() is not { } kind) return;
                dragStart = model.Current;
                var a = new Annotation(kind, p, p, style: model.StyleFor(model.Tool));
                if (kind == AnnotationKind.Pen) a.Points = [p];
                model.Insert(a);
                drag = DragKind.Creating;
                dragId = a.Id;
                break;
            }
        }
    }

    private void Canvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (model == null) return;
        UpdateCursor(e);
        if (drag == DragKind.None) return;
        var p = ImagePoint(e);
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift);
        switch (drag)
        {
            case DragKind.Creating:
                model.Update(dragId, a =>
                {
                    if (a.Kind == AnnotationKind.Pen)
                    {
                        if (a.Points.Count > 0 && Geometry.Distance(a.Points[^1], p) < 1.5) return;
                        a.Points.Add(p);
                        a.End = p;
                    }
                    else if (shift)
                        a.End = a.Kind is AnnotationKind.Arrow or AnnotationKind.Line ? Geometry.SnapAngle(a.Start, p) : Geometry.SnapSquare(a.Start, p);
                    else a.End = p;
                });
                break;
            case DragKind.Moving when dragOriginal != null:
                model.Update(dragId, a =>
                {
                    a.Start = dragOriginal.Start; a.End = dragOriginal.End; a.Points = [.. dragOriginal.Points];
                    a.Translate(p.X - dragOrigin.X, p.Y - dragOrigin.Y);
                });
                break;
            case DragKind.Handle:
                model.Update(dragId, a => a.MoveHandle(dragHandle, p));
                break;
            case DragKind.Cropping:
                model.CropRect = Geometry.Rect(dragOrigin, p).Intersect(model.ImageBounds);
                model.NotifyChanged();
                break;
        }
    }

    private void UpdateCursor(PointerRoutedEventArgs e)
    {
        if (model == null) return;
        var shape = model.Tool switch { Tool.Select => InputSystemCursorShape.Arrow, Tool.Text => InputSystemCursorShape.IBeam, _ => InputSystemCursorShape.Cross };
        if (model.Tool != Tool.Crop && model.Selected is { } sel)
        {
            var p = ImagePoint(e);
            if (HandleIndex(p, sel) != null) shape = InputSystemCursorShape.SizeAll;
            else if (sel.HitTest(p, HitTolerance)) shape = InputSystemCursorShape.SizeAll;
        }
        // ProtectedCursor is protected on UIElement; setting it from outside needs reflection.
        CursorProperty ??= typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        CursorProperty?.SetValue(Canvas, InputSystemCursor.Create(shape));
    }

    private static System.Reflection.PropertyInfo? CursorProperty;

    private void Canvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Canvas.ReleasePointerCapture(e.Pointer);
        if (model == null) return;
        try
        {
            switch (drag)
            {
                case DragKind.Creating:
                    if (model.Find(dragId) is not { } a) return;
                    if (a.IsDegenerate) { model.RemoveSilently(dragId); model.Select(null); return; }
                    model.Select(dragId);
                    if (dragStart != null) model.RegisterUndo(dragStart);
                    break;
                case DragKind.Moving or DragKind.Handle:
                    // A picture dragged past the edge makes the page bigger instead of being cut off.
                    if (model.Find(dragId)?.Kind == AnnotationKind.Image && model.GrowCanvas(dragId)) LayoutCanvas();
                    if (dragStart != null && (RasterNestJson.Serialize(dragStart.Annotations) != RasterNestJson.Serialize(model.Annotations)
                                              || !ReferenceEquals(dragStart.Image, model.Image)))
                        model.RegisterUndo(dragStart);
                    break;
                case DragKind.Cropping:
                    if (model.CropRect is { } r && (r.Width < 4 || r.Height < 4)) { model.CropRect = null; model.NotifyChanged(); }
                    break;
            }
        }
        finally
        {
            drag = DragKind.None;
            dragStart = null;
            dragOriginal = null;
        }
    }

    private void Canvas_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (model == null) return;
        var pos = e.GetPosition(Canvas);
        var p = new PointD(pos.X * RasterScale / zoom - Padding, pos.Y * RasterScale / zoom - Padding);
        if (Hit(p) is { Kind: AnnotationKind.Text } t) { model.Select(t.Id); BeginEditing(t.Id, false); }
    }

    /// <summary>Right-click: copy the image or its text anywhere; on an annotation, its own actions too.</summary>
    private void Canvas_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (model == null) return;
        var pos = e.GetPosition(Canvas);
        var p = new PointD(pos.X * RasterScale / zoom - Padding, pos.Y * RasterScale / zoom - Padding);
        var menu = new MenuFlyout();
        void Add(string text, Action action, string? glyph = null)
        {
            var mi = new MenuFlyoutItem { Text = text };
            if (glyph != null) mi.Icon = new FontIcon { Glyph = glyph };
            mi.Click += (_, _) => action();
            menu.Items.Add(mi);
        }
        Add("Copy Image", CopyImage, "");
        Add("Copy Text", CopyText, "");
        if (model.Annotations.Any(a => a.Kind == AnnotationKind.Image)) Add("Fit Canvas to Content", () => { model.FitCanvasToContent(); LayoutCanvas(); });
        if (Hit(p) is { } h)
        {
            model.Select(h.Id);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add("Duplicate", model.DuplicateSelected);
            Add("Bring to Front", model.BringSelectedToFront);
            Add("Send to Back", model.SendSelectedToBack);
            menu.Items.Add(new MenuFlyoutSeparator());
            Add("Delete", model.DeleteSelected, "");
        }
        menu.ShowAt(Canvas, pos);
    }

    // MARK: keyboard

    private void Root_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (model == null) return;
        if (e.OriginalSource is TextBox) return;
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        var step = shift ? 10.0 : 1.0;
        e.Handled = true;
        switch (e.Key)
        {
            case VirtualKey.Z when ctrl && shift: model.Redo(); return;
            case VirtualKey.Z when ctrl: model.Undo(); return;
            case VirtualKey.Y when ctrl: model.Redo(); return;
            case VirtualKey.C when ctrl: CopyImage(); return;
            case VirtualKey.S when ctrl && shift: Export_Click(this, new RoutedEventArgs()); return;
            case VirtualKey.S when ctrl: SaveIfNeeded(); UpdateChrome(); return;
            case VirtualKey.V when ctrl: PasteImage(); return;
            case VirtualKey.D when ctrl: model.DuplicateSelected(); return;
            case VirtualKey.N when ctrl: App.CurrentApp?.NewFromClipboard(); return;
            case VirtualKey.O when ctrl: App.CurrentApp?.OpenFile(); return;
            case VirtualKey.W when ctrl: Close(); return;
            case (VirtualKey)188 when ctrl: SettingsWindow.ShowShared(); return; // Ctrl+,
            case (VirtualKey)187 or VirtualKey.Add when ctrl: SetZoom(zoom * 1.25); return; // Ctrl+=/+
            case (VirtualKey)189 or VirtualKey.Subtract when ctrl: SetZoom(zoom / 1.25); return;
            case VirtualKey.Number0 when ctrl: SetZoom(FitZoom()); return;
            case VirtualKey.Number1 when ctrl: SetZoom(1); return;
            case VirtualKey.Delete or VirtualKey.Back: model.DeleteSelected(); return;
            case VirtualKey.Escape:
                if (model.CropRect != null) { model.CropRect = null; model.NotifyChanged(); } else model.Select(null);
                return;
            case VirtualKey.Enter:
                if (model.Tool == Tool.Crop) { model.ApplyCrop(); LayoutCanvas(); }
                else if (model.Selected is { Kind: AnnotationKind.Text } t) BeginEditing(t.Id, false);
                return;
            case VirtualKey.Left when model.SelectedId != null: model.NudgeSelected(-step, 0); return;
            case VirtualKey.Right when model.SelectedId != null: model.NudgeSelected(step, 0); return;
            case VirtualKey.Up when model.SelectedId != null: model.NudgeSelected(0, -step); return;
            case VirtualKey.Down when model.SelectedId != null: model.NudgeSelected(0, step); return;
        }
        if (!ctrl && (int)e.Key is >= 'A' and <= 'Z' && Tools.All.FirstOrDefault(t => t.Shortcut() == (char)e.Key) is var tool && tool.Shortcut() == (char)e.Key)
        {
            model.Tool = tool;
            return;
        }
        e.Handled = false;
    }

    // MARK: text editing

    private void CreateText(PointD p)
    {
        var pre = model!.Current;
        var a = new Annotation(AnnotationKind.Text, p, style: model.StyleFor(Tool.Text));
        a.Start = a.Start with { Y = a.Start.Y - a.Style.FontSize * 0.6 }; // centre the first line on the click
        TextMetrics.Layout(a);
        model.Insert(a);
        model.Select(a.Id);
        BeginEditing(a.Id, true, pre);
    }

    private void BeginEditing(Guid id, bool isNew, EditorModel.Snapshot? previous = null)
    {
        if (model?.Find(id) is not { } a) return;
        FinishEditing();
        editingId = id;
        editingIsNew = isNew;
        editingSnapshot = previous ?? model.Current;
        var c = TextMetrics.TextColor(a);
        textBox = new TextBox
        {
            Text = a.Text,
            AcceptsReturn = true,
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Foreground = new SolidColorBrush(global::Windows.UI.Color.FromArgb(c.Alpha, c.Red, c.Green, c.Blue)),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Padding = new Thickness(0),
            MinWidth = 20,
            TextWrapping = TextWrapping.NoWrap,
        };
        textBox.Resources["TextControlBackgroundFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        textBox.Resources["TextControlBackgroundPointerOver"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        textBox.Resources["TextControlForegroundFocused"] = textBox.Foreground;
        textBox.Resources["TextControlBorderBrushFocused"] = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        textBox.TextChanged += (_, _) => { if (editingId is { } eid) { model.Update(eid, x => x.Text = textBox?.Text ?? ""); LayoutTextBox(); } };
        textBox.LostFocus += (_, _) => FinishEditing();
        textBox.KeyDown += (s, e) =>
        {
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
            if (e.Key == VirtualKey.Enter && !shift) { e.Handled = true; FinishEditing(); Scroller.Focus(FocusState.Programmatic); }
            else if (e.Key == VirtualKey.Escape) { e.Handled = true; FinishEditing(); Scroller.Focus(FocusState.Programmatic); }
        };
        TextLayer.Children.Add(textBox);
        LayoutTextBox();
        textBox.Focus(FocusState.Programmatic);
        textBox.SelectAll();
        Canvas.Invalidate();
    }

    private void LayoutTextBox()
    {
        if (textBox == null || editingId is not { } id || model?.Find(id) is not { } a) return;
        var k = zoom / RasterScale;
        var p = TextMetrics.Padding(a);
        textBox.FontSize = Math.Max(4, a.Style.FontSize * k * 0.98);
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(textBox, (a.Start.X + Padding + p) * k);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(textBox, (a.Start.Y + Padding + p) * k - textBox.FontSize * 0.12);
    }

    private void FinishEditing()
    {
        if (editingId is not { } id || textBox == null || model == null) return;
        var text = textBox.Text;
        editingId = null;
        TextLayer.Children.Remove(textBox);
        textBox = null;
        var pre = editingSnapshot;
        editingSnapshot = null;
        if (string.IsNullOrWhiteSpace(text))
        {
            model.RemoveSilently(id);
            if (!editingIsNew && pre != null) model.RegisterUndo(pre);
        }
        else
        {
            model.Update(id, a => a.Text = text.Replace("\r", "\n"));
            if (pre != null) model.RegisterUndo(pre);
        }
        Canvas.Invalidate();
    }

    // MARK: inspector

    private void BuildInspector()
    {
        Inspector.Children.Clear();
        if (VideoHost.Visibility == Visibility.Visible && videoPane != null)
        {
            Inspector.Children.Add(videoPane.Inspector);
            return;
        }
        if (model == null) return;
        if (model.Tool == Tool.Crop)
        {
            Inspector.Children.Add(Header("Crop"));
            var apply = new Button { Content = "Apply Crop", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            apply.Click += (_, _) => { model.ApplyCrop(); LayoutCanvas(); };
            var cancel = new Button { Content = "Cancel" };
            cancel.Click += (_, _) => { model.CropRect = null; model.Tool = Tool.Select; };
            Inspector.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { apply, cancel } });
        }
        else if (model.InspectedKind is { } kind)
        {
            var sel = model.Selected;
            Inspector.Children.Add(Header(sel != null ? $"{Tools.FromKind(kind)?.Title() ?? kind.ToString()} (selected)" : (Tools.FromKind(kind)?.Title() ?? kind.ToString())));
            var style = model.InspectedStyle;
            var s = model.PixelScale;

            if (kind is not (AnnotationKind.Pixelate or AnnotationKind.Spotlight or AnnotationKind.Image))
                Inspector.Children.Add(ColorRow(style.Color));

            switch (kind)
            {
                case AnnotationKind.Arrow or AnnotationKind.Line or AnnotationKind.Rectangle or AnnotationKind.Ellipse or AnnotationKind.Pen:
                    Inspector.Children.Add(SliderRow("Width", style.LineWidth / s, 1, 20, v => model.UpdateInspectedStyle("width", st => st.LineWidth = v * s)));
                    if (kind == AnnotationKind.Arrow)
                        Inspector.Children.Add(ToggleRow("Both Ends", style.IsDoubleHeaded, v => model.UpdateInspectedStyle("heads", st => st.Heads = v ? 2 : null)));
                    if (kind is AnnotationKind.Rectangle or AnnotationKind.Ellipse)
                        Inspector.Children.Add(ToggleRow("Filled", style.Filled, v => model.UpdateInspectedStyle("filled", st => st.Filled = v)));
                    Inspector.Children.Add(ToggleRow("Shadow", style.Shadow, v => model.UpdateInspectedStyle("shadow", st => st.Shadow = v)));
                    break;
                case AnnotationKind.Text:
                    Inspector.Children.Add(SliderRow("Size", style.FontSize / s, 8, 72, v => model.UpdateInspectedStyle("size", st => st.FontSize = v * s)));
                    Inspector.Children.Add(ToggleRow("Callout", style.Filled, v => model.UpdateInspectedStyle("filled", st => st.Filled = v)));
                    Inspector.Children.Add(ToggleRow("Shadow", style.Shadow, v => model.UpdateInspectedStyle("shadow", st => st.Shadow = v)));
                    break;
                case AnnotationKind.Step:
                    Inspector.Children.Add(SliderRow("Size", style.FontSize / s, 8, 40, v => model.UpdateInspectedStyle("size", st => st.FontSize = v * s)));
                    Inspector.Children.Add(ToggleRow("Shadow", style.Shadow, v => model.UpdateInspectedStyle("shadow", st => st.Shadow = v)));
                    break;
                case AnnotationKind.Highlight:
                    Inspector.Children.Add(SliderRow("Opacity", style.Opacity * 100, 10, 90, v => model.UpdateInspectedStyle("opacity", st => st.Opacity = v / 100)));
                    break;
                case AnnotationKind.Pixelate:
                {
                    Inspector.Children.Add(new TextBlock { Text = "Hide with", Opacity = 0.7 });
                    Inspector.Children.Add(Segmented(["Pixelate", "Blur"], style.IsBlur ? 1 : 0, i =>
                    {
                        model.UpdateInspectedStyle("blur", st => st.Blur = i == 1 ? true : null);
                        BuildInspector();
                    }));
                    Inspector.Children.Add(SliderRow("Strength", style.LineWidth / s, 4, 40, v => model.UpdateInspectedStyle("width", st => st.LineWidth = v * s)));
                    break;
                }
                case AnnotationKind.Spotlight:
                    Inspector.Children.Add(SliderRow("Dim", style.Opacity * 100, 10, 90, v => model.UpdateInspectedStyle("opacity", st => st.Opacity = v / 100)));
                    break;
                case AnnotationKind.Magnify:
                    Inspector.Children.Add(SliderRow("Zoom", style.ZoomFactor * 100, 120, 600, v => model.UpdateInspectedStyle("zoom", st => st.Zoom = v / 100), "%"));
                    Inspector.Children.Add(SliderRow("Rim", style.LineWidth / s, 0, 12, v => model.UpdateInspectedStyle("width", st => st.LineWidth = v * s)));
                    Inspector.Children.Add(ToggleRow("Rounded square", style.Filled, v => model.UpdateInspectedStyle("filled", st => st.Filled = v)));
                    break;
                case AnnotationKind.Image:
                    Inspector.Children.Add(SliderRow("Border", style.LineWidth / s, 0, 12, v => model.UpdateInspectedStyle("width", st => st.LineWidth = v * s)));
                    if (style.LineWidth > 0) Inspector.Children.Add(ColorRow(style.Color));
                    Inspector.Children.Add(SliderRow("Opacity", style.Opacity * 100, 5, 100, v => model.UpdateInspectedStyle("opacity", st => st.Opacity = v / 100)));
                    Inspector.Children.Add(ToggleRow("Shadow", style.Shadow, v => model.UpdateInspectedStyle("shadow", st => st.Shadow = v)));
                    if (sel != null)
                    {
                        var number = new NumberBox { Header = "Step number (0 = none)", Value = sel.Number, Minimum = 0, Maximum = 99, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
                        number.ValueChanged += (_, a) => { if (!double.IsNaN(a.NewValue)) model.SetSelectedNumber((int)a.NewValue); };
                        Inspector.Children.Add(number);
                    }
                    var fit = new Button { Content = "Fit Canvas to Content" };
                    fit.Click += (_, _) => { model.FitCanvasToContent(); LayoutCanvas(); };
                    Inspector.Children.Add(fit);
                    break;
            }
            if (sel != null)
            {
                var delete = new Button { Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { new FontIcon { Glyph = "", FontSize = 14 }, new TextBlock { Text = "Delete" } } } };
                delete.Click += (_, _) => model.DeleteSelected();
                Inspector.Children.Add(delete);
            }
        }
        else
        {
            Inspector.Children.Add(new TextBlock { Text = "Click an annotation to edit it, or pick a tool above.", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        }
        Inspector.Children.Add(new MenuFlyoutSeparator { Margin = new Thickness(0, 8, 0, 0) });
        BuildFrameControls();
    }

    private static TextBlock Header(string text) => new() { Text = text, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };

    private FrameworkElement ColorRow(Rgba current)
    {
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock { Text = "Color", Opacity = 0.7 });
        // Wraps onto more lines when the inspector is narrow.
        var swatches = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 30, ItemHeight = 30 };
        foreach (var c in Rgba.Palette)
        {
            var sk = c.ToSK();
            var b = new Button
            {
                Width = 24, Height = 24, Padding = new Thickness(0), CornerRadius = new CornerRadius(12),
                Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, sk.Red, sk.Green, sk.Blue)),
                BorderThickness = new Thickness(c == current ? 3 : 1),
                BorderBrush = new SolidColorBrush(c == current ? global::Windows.UI.Color.FromArgb(255, 0x7C, 0x3A, 0xED) : global::Windows.UI.Color.FromArgb(80, 0, 0, 0)),
            };
            ToolTipService.SetToolTip(b, c.Hex);
            b.Click += (_, _) => { model!.UpdateInspectedStyle("color", st => st.Color = c with { A = st.Color.A }); BuildInspector(); };
            swatches.Children.Add(b);
        }
        // Any colour.
        var picker = new ColorPicker { IsAlphaEnabled = false, IsMoreButtonVisible = true };
        var cur = current.ToSK();
        picker.Color = global::Windows.UI.Color.FromArgb(255, cur.Red, cur.Green, cur.Blue);
        picker.ColorChanged += (_, e) => model!.UpdateInspectedStyle("color", st => st.Color = new Rgba(e.NewColor.R / 255.0, e.NewColor.G / 255.0, e.NewColor.B / 255.0, st.Color.A));
        var more = new Button { Width = 24, Height = 24, Padding = new Thickness(0), Content = new FontIcon { Glyph = "", FontSize = 12 }, Flyout = new Flyout { Content = picker } };
        ToolTipService.SetToolTip(more, "More colours");
        swatches.Children.Add(more);
        panel.Children.Add(swatches);
        return panel;
    }

    /// <summary>A row of buttons where exactly one is on (a segmented control).</summary>
    private static FrameworkElement Segmented(string[] labels, int selected, Action<int> changed)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        for (var i = 0; i < labels.Length; i++)
        {
            var index = i;
            var b = new ToggleButton
            {
                Content = labels[i], IsChecked = i == selected, MinWidth = 88,
                CornerRadius = new CornerRadius(i == 0 ? 4 : 0, i == labels.Length - 1 ? 4 : 0, i == labels.Length - 1 ? 4 : 0, i == 0 ? 4 : 0),
            };
            b.Click += (_, _) =>
            {
                foreach (var other in row.Children.OfType<ToggleButton>()) other.IsChecked = other == b;
                changed(index);
            };
            row.Children.Add(b);
        }
        return row;
    }

    private static FrameworkElement SliderRow(string label, double value, double min, double max, Action<double> changed, string unit = "")
    {
        var panel = new StackPanel { Spacing = 0 };
        var title = new TextBlock { Text = $"{label}  {Math.Round(value)}{unit}", Opacity = 0.7 };
        var slider = new Slider { Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max), StepFrequency = 1 };
        slider.ValueChanged += (_, e) => { title.Text = $"{label}  {Math.Round(e.NewValue)}{unit}"; changed(e.NewValue); };
        panel.Children.Add(title);
        panel.Children.Add(slider);
        return panel;
    }

    private static FrameworkElement ToggleRow(string label, bool value, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { Header = label, IsOn = value, OnContent = "On", OffContent = "Off" };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        return toggle;
    }

    /// <summary>Frame: padding, background, corners, shadow, border; presets; default for new captures.</summary>
    private void BuildFrameControls()
    {
        if (model == null) return;
        var s = model.PixelScale;
        var e = model.Effects;
        Inspector.Children.Add(Header("Frame"));
        var presets = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 78, ItemHeight = 38 };
        foreach (var (name, make) in new (string, Func<CanvasEffects>)[]
                 { ("None", () => CanvasEffects.None), ("Docs", () => CanvasEffects.Documentation(s)),
                   ("Shadow", () => new CanvasEffects { Padding = 40 * s, Shadow = true, CornerRadius = 8 * s }),
                   ("Border", () => new CanvasEffects { BorderWidth = 2 * s, CornerRadius = 6 * s }) })
        {
            var b = new Button { Content = name, Padding = new Thickness(6, 4, 6, 4), Width = 72 };
            b.Click += (_, _) => { model.UpdateEffects("preset", _ => make()); LayoutCanvas(); BuildInspector(); };
            presets.Children.Add(b);
        }
        Inspector.Children.Add(presets);
        var bg = new ComboBox { Header = "Background", ItemsSource = new[] { "None", "Solid", "Gradient" }, SelectedIndex = (int)e.Background, MinWidth = 160 };
        bg.SelectionChanged += (_, _) => model.UpdateEffects("bg", x => x with { Background = (FrameBackground)bg.SelectedIndex });
        Inspector.Children.Add(bg);
        Inspector.Children.Add(SliderRow("Padding", e.Padding / s, 0, 120, v => { model.UpdateEffects("padding", x => x with { Padding = v * s }); LayoutCanvas(); }));
        Inspector.Children.Add(SliderRow("Corners", e.CornerRadius / s, 0, 40, v => model.UpdateEffects("corners", x => x with { CornerRadius = v * s })));
        Inspector.Children.Add(SliderRow("Border", e.BorderWidth / s, 0, 12, v => model.UpdateEffects("border", x => x with { BorderWidth = v * s })));
        Inspector.Children.Add(ToggleRow("Drop shadow", e.Shadow, v => model.UpdateEffects("shadow", x => x with { Shadow = v })));
        var useDefault = new Button { Content = "Use for New Captures" };
        useDefault.Click += (_, _) =>
        {
            var x = model.Effects;
            AppSettings.Shared.DefaultFrame = x.IsEmpty ? null : x with { Padding = x.Padding / s, CornerRadius = x.CornerRadius / s, BorderWidth = x.BorderWidth / s };
            AppSettings.Shared.Save();
            Status.Text = x.IsEmpty ? "New captures won't get a frame." : "New captures will get this frame.";
        };
        Inspector.Children.Add(useDefault);
    }

    // MARK: strip

    private void RefreshStrip()
    {
        loadingStrip = true;
        Strip.Items.Clear();
        foreach (var i in CaptureLibrary.Shared.Items.Take(120))
        {
            var image = new Image { Height = ThumbnailHeight, Stretch = Stretch.Uniform };
            if (CaptureLibrary.Shared.Thumbnail(i) is { } png) image.Source = ToBitmapImage(png);
            else if (i.IsVideo) image.Source = null;
            var label = new TextBlock { Text = i.IsVideo ? "▶ " + i.Name : i.Name, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0.8 };
            var panel = new StackPanel { Spacing = 2, Padding = new Thickness(0, 4, 0, 4), Children = { image, label }, Tag = i };
            var menu = new MenuFlyout();
            var reveal = new MenuFlyoutItem { Text = "Show in File Explorer" };
            reveal.Click += (_, _) => System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{i.SharePath}\"");
            var delete = new MenuFlyoutItem { Text = "Move to Recycle Bin" };
            delete.Click += (_, _) =>
            {
                if (item?.Id == i.Id)
                {
                    videoPane?.Stop();
                    model?.Dispose();
                    model = null;
                    item = null;
                    Canvas.Invalidate();
                }
                CaptureLibrary.Shared.Delete(i);
            };
            if (!i.IsVideo)
            {
                var combine = new MenuFlyoutItem { Text = "Add to Combine", Icon = new FontIcon { Glyph = "\uF0E2" } };
                combine.Click += (_, _) => AddToCombine(i);
                menu.Items.Add(combine);
            }
            menu.Items.Add(reveal);
            menu.Items.Add(delete);
            panel.ContextFlyout = menu;
            Strip.Items.Add(new ListViewItem { Content = panel, Tag = i });
        }
        if (item != null) SelectInStrip(item.Id);
        loadingStrip = false;
    }

    private void SelectInStrip(string id)
    {
        var was = loadingStrip;
        loadingStrip = true;
        Strip.SelectedItem = Strip.Items.OfType<ListViewItem>().FirstOrDefault(x => (x.Tag as CaptureLibrary.Item)?.Id == id);
        loadingStrip = was;
    }

    private void Strip_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loadingStrip || Strip.SelectedItem is not ListViewItem { Tag: CaptureLibrary.Item i }) return;
        Open(i);
    }

    /// <summary>Text marker for drags that start in the strip, so drops inside RasterNest resolve instantly.</summary>
    internal const string StripDragPrefix = "rasternest-capture:";

    private void Strip_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        Log.Write($"drag start: {e.Items.Count} item(s), first={e.Items.FirstOrDefault()?.GetType().Name}");
        // The dragged item may arrive as the ListViewItem or as its content (the thumbnail panel); both carry the capture.
        if ((e.Items.FirstOrDefault() as FrameworkElement)?.Tag is not CaptureLibrary.Item i) return;
        // Don't save here: saving refreshes the strip, which would cancel this drag. Drop targets save first instead.
        e.Data.RequestedOperation = DataPackageOperation.Copy;
        e.Data.SetText(StripDragPrefix + (i.HasDocument ? i.DocumentPath : i.SharePath));
        // A real file for other apps (mail, chat, Explorer), produced only if one of them asks.
        var share = i.SharePath;
        e.Data.SetDataProvider(StandardDataFormats.StorageItems, async request =>
        {
            var deferral = request.GetDeferral();
            try { request.SetData(new List<IStorageItem> { await StorageFile.GetFileFromPathAsync(share) }); }
            catch { }
            finally { deferral.Complete(); }
        });
    }

    /// <summary>Files dropped on the editor or the Combine pane: a capture from the strip, or files from Explorer.</summary>
    internal static async Task<List<string>> DroppedPaths(DataPackageView view)
    {
        var paths = new List<string>();
        if (view.Contains(StandardDataFormats.Text) && await view.GetTextAsync() is { } text && text.StartsWith(StripDragPrefix, StringComparison.Ordinal))
        {
            paths.Add(text[StripDragPrefix.Length..]);
            return paths;
        }
        if (view.Contains(StandardDataFormats.StorageItems))
            foreach (var f in await view.GetStorageItemsAsync())
                if (f is StorageFile file) paths.Add(file.Path);
        return paths;
    }

    private static BitmapImage ToBitmapImage(byte[] png)
    {
        var bmp = new BitmapImage();
        using var stream = new global::Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new global::Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png);
            writer.StoreAsync().AsTask().GetAwaiter().GetResult();
        }
        stream.Seek(0);
        bmp.SetSource(stream);
        return bmp;
    }

    // MARK: drop and paste pictures as layers

    private bool loggedDragOver;

    private void Canvas_DragOver(object sender, DragEventArgs e)
    {
        if (!loggedDragOver) { loggedDragOver = true; Log.Write($"drag over canvas: formats={string.Join(",", e.DataView.AvailableFormats)}"); }
        if (e.DataView.Contains(StandardDataFormats.StorageItems) || e.DataView.Contains(StandardDataFormats.Bitmap) || e.DataView.Contains(StandardDataFormats.Text))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Add as a layer";
        }
    }

    private async void Canvas_Drop(object sender, DragEventArgs e)
    {
        loggedDragOver = false;
        Log.Write("drop on canvas");
        if (model == null) return;
        var pos = e.GetPosition(Canvas);
        var center = new PointD(pos.X * RasterScale / zoom - Padding, pos.Y * RasterScale / zoom - Padding);
        var pictures = new List<(byte[] Png, SizeD Size, double Scale)>();
        var paths = await DroppedPaths(e.DataView);
        SaveIfNeeded();
        // Dropping a capture on itself would only duplicate it.
        paths.RemoveAll(p => item != null && (string.Equals(p, item.DocumentPath, StringComparison.OrdinalIgnoreCase)
                                              || string.Equals(p, item.ImagePath, StringComparison.OrdinalIgnoreCase)));
        Log.Write($"drop paths: {string.Join(" | ", paths)}");
        foreach (var path in paths) if (Picture(path) is { } pic) pictures.Add(pic);
        Log.Write($"drop pictures: {pictures.Count}");
        if (paths.Count == 0 && e.DataView.Contains(StandardDataFormats.Bitmap) && await ReadBitmap(await e.DataView.GetBitmapAsync()) is { } bmp) pictures.Add(bmp);
        foreach (var p in pictures)
        {
            model.AddImageLayer(p.Png, p.Size, p.Scale, center);
            center = center.Offset(24 * model.PixelScale, 24 * model.PixelScale);
        }
    }

    private static (byte[] Png, SizeD Size, double Scale)? Picture(string path)
    {
        try
        {
            if (path.EndsWith("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
            {
                var doc = NestDocument.Load(path);
                using var bitmap = ImageCodec.Decode(doc.ImagePng)!.Value.Bitmap;
                using var flat = new AnnotationRenderer(doc.PixelScale).Flatten(bitmap, doc.Annotations, doc.Effects);
                return (ImageCodec.Encode(flat, ExportFormat.Png, doc.PixelScale), new SizeD(flat.Width, flat.Height), doc.PixelScale);
            }
            if (!CaptureLibrary.ImageExtensions.Contains(Path.GetExtension(path).ToLowerInvariant())) return null;
            var loaded = ImageCodec.Load(path);
            if (loaded is not { } l) return null;
            using (l.Bitmap) return (ImageCodec.EncodePng(l.Bitmap, l.Scale), new SizeD(l.Bitmap.Width, l.Bitmap.Height), l.Scale);
        }
        catch { return null; }
    }

    private static async Task<(byte[] Png, SizeD Size, double Scale)?> ReadBitmap(global::Windows.Storage.Streams.RandomAccessStreamReference reference)
    {
        using var stream = await reference.OpenReadAsync();
        var bytes = new byte[stream.Size];
        using (var reader = new global::Windows.Storage.Streams.DataReader(stream))
        {
            await reader.LoadAsync((uint)stream.Size);
            reader.ReadBytes(bytes);
        }
        var decoded = ImageCodec.Decode(bytes);
        if (decoded is not { } d) return null;
        using (d.Bitmap) return (ImageCodec.EncodePng(d.Bitmap, d.Scale), new SizeD(d.Bitmap.Width, d.Bitmap.Height), d.Scale);
    }

    private async void PasteImage()
    {
        if (model == null) return;
        var view = global::Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (view.Contains(StandardDataFormats.StorageItems))
        {
            foreach (var f in await view.GetStorageItemsAsync())
                if (f is StorageFile file && Picture(file.Path) is { } pic) model.AddImageLayer(pic.Png, pic.Size, pic.Scale);
        }
        else if (view.Contains(StandardDataFormats.Bitmap) && await ReadBitmap(await view.GetBitmapAsync()) is { } bmp)
            model.AddImageLayer(bmp.Png, bmp.Size, bmp.Scale);
    }

    // MARK: copy and export

    private void Copy_Click(object sender, RoutedEventArgs e) => CopyImage();

    private void CopyImage()
    {
        if (model == null) return;
        FinishEditing();
        using var flat = model.Flattened();
        RasterNest.Windows.Clipboard.CopyImage(flat, model.PixelScale);
        Status.Text = "Copied the image.";
    }

    private async void CopyText()
    {
        if (model == null) return;
        try
        {
            using var bmp = SKBitmap.FromImage(model.Image);
            var lines = await TextRecognition.AnalyzeAsync(bmp);
            var text = string.Join("\n", lines.Select(l => l.Text));
            if (text.Length == 0) { Status.Text = "No text found."; return; }
            RasterNest.Windows.Clipboard.CopyText(text);
            Status.Text = $"Copied {lines.Count} line{(lines.Count == 1 ? "" : "s")} of text.";
        }
        catch (Exception ex) { Status.Text = $"Couldn't read text: {ex.Message}"; }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (model == null || item == null) return;
        FinishEditing();
        var picker = new FileSavePicker { SuggestedFileName = item.Name, SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        picker.FileTypeChoices.Add("PNG image", [".png"]);
        picker.FileTypeChoices.Add("JPEG image", [".jpg"]);
        picker.FileTypeChoices.Add("PDF", [".pdf"]);
        picker.FileTypeChoices.Add("RasterNest document (editable)", [".rasternest"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        try
        {
            var ext = Path.GetExtension(file.Path).ToLowerInvariant();
            if (ext == ".rasternest") model.MakeDocument().Save(file.Path);
            else
            {
                using var flat = model.Flattened();
                if (ext == ".pdf") PdfComposer.Write([new PdfComposer.Page(flat, model.PixelScale)], file.Path, title: item.Name);
                else await File.WriteAllBytesAsync(file.Path, ImageCodec.Encode(flat, ext == ".jpg" ? ExportFormat.Jpg : ExportFormat.Png, model.PixelScale));
            }
            Status.Text = $"Saved {file.Path}";
        }
        catch (Exception ex) { Status.Text = $"Couldn't save: {ex.Message}"; }
    }

    // MARK: combine

    private CombinePane? combinePane;

    private void Combine_Click(object sender, RoutedEventArgs e) => SetCombineVisible(CombineToggle.IsChecked == true);

    private void SetCombineVisible(bool visible)
    {
        CombineToggle.IsChecked = visible;
        if (visible && combinePane == null)
        {
            combinePane = new CombinePane(() => item, SaveIfNeeded, created =>
            {
                Open(created);
                Status.Text = "Combined. Each picture is a layer: drag to move, drag a corner to resize.";
            }, () => SetCombineVisible(false));
            CombineHost.Child = combinePane;
        }
        var wasVisible = CombineHost.Visibility == Visibility.Visible;
        if (visible != wasVisible)
        {
            // Make room instead of squeezing the picture (the Mac widens its window the same way).
            var extra = (int)Math.Round(AppSettings.Shared.CombineWidth * RasterScale) * (visible ? 1 : -1);
            var size = AppWindow.Size;
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Nearest).WorkArea;
            var width = Math.Clamp(size.Width + extra, 800, area.Width);
            var x = Math.Min(AppWindow.Position.X, area.X + area.Width - width);
            AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(Math.Max(area.X, x), AppWindow.Position.Y, width, size.Height));
        }
        CombineColumn.Width = new GridLength(visible ? AppSettings.Shared.CombineWidth : 0);
        CombineHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AddToCombine(CaptureLibrary.Item i)
    {
        SaveIfNeeded();
        SetCombineVisible(true);
        combinePane!.Add(i.HasDocument ? i.DocumentPath : i.SharePath);
    }
}
