using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using RasterNest.App.Library;
using RasterNest.Core;
using RasterNest.Render;
using SkiaSharp;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.Storage;

namespace RasterNest.App.Editor;

/// <summary>
/// Side panel: drag captures in from the strip (or images from File Explorer), arrange them, combine.
/// The result is a new capture whose pictures are separate layers, so they can still be moved, resized and
/// overlapped in the editor. A port of the Mac CombinePane.
/// </summary>
internal sealed class CombinePane : Grid
{
    /// <summary>One picture waiting to be combined (bound into the reorderable list).</summary>
    public sealed class Entry(string path, string name, byte[] thumbnailPng, SizeD pixelSize) : System.ComponentModel.INotifyPropertyChanged
    {
        public string Path { get; } = path;
        public string Name { get; } = name;
        public byte[] ThumbnailPng { get; } = thumbnailPng;
        public SizeD PixelSize { get; } = pixelSize;
        public BitmapImage Thumbnail { get; } = ToBitmap(thumbnailPng);
        private string number = "";
        public string Number { get => number; set { number = value; PropertyChanged?.Invoke(this, new(nameof(Number))); } }
        public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    }

    private readonly System.Collections.ObjectModel.ObservableCollection<Entry> entries = [];
    private CombineArrangement arrangement = CombineArrangement.Horizontal;
    private double gap = 24;
    private bool matchSizes = true, transparent, numbered = true;

    private readonly Func<CaptureLibrary.Item?> currentItem;
    private readonly Action commit;
    private readonly Action<CaptureLibrary.Item> created;
    private readonly Action close;

    private readonly Border dropArea;
    private readonly Grid preview = new() { Height = 140 };
    private readonly TextBlock emptyText = new()
    {
        Text = "Drag captures here from the strip, or images from File Explorer.",
        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Opacity = 0.65, FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly ListView list = new()
    {
        CanReorderItems = true, CanDragItems = true, AllowDrop = true, SelectionMode = ListViewSelectionMode.None,
        ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            """
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <Grid ColumnSpacing="8" Padding="0,4">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="20" /><ColumnDefinition Width="84" /><ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <TextBlock Text="{Binding Number}" Opacity="0.6" VerticalAlignment="Center" />
                <Border Grid.Column="1" CornerRadius="4" BorderThickness="1" BorderBrush="#40808080">
                  <Image Source="{Binding Thumbnail}" Height="56" Stretch="Uniform" />
                </Border>
                <TextBlock Grid.Column="2" Text="{Binding Name}" FontSize="12" TextWrapping="Wrap" MaxLines="2"
                           TextTrimming="CharacterEllipsis" VerticalAlignment="Center" />
              </Grid>
            </DataTemplate>
            """),
    };
    private readonly Button combineButton = new() { Content = "Combine", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
    private readonly Button clearButton = new() { Content = "Clear" };

    public CombinePane(Func<CaptureLibrary.Item?> currentItem, Action commit, Action<CaptureLibrary.Item> created, Action close)
    {
        this.currentItem = currentItem;
        this.commit = commit;
        this.created = created;
        this.close = close;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid { Padding = new Thickness(12, 8, 6, 8) };
        header.Children.Add(new TextBlock { Text = "Combine", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center });
        var closeButton = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, HorizontalAlignment = HorizontalAlignment.Right, Style = (Style)Application.Current.Resources["SubtleButtonStyle"] };
        ToolTipService.SetToolTip(closeButton, "Close");
        closeButton.Click += (_, _) => close();
        header.Children.Add(closeButton);
        Children.Add(header);

        var body = new StackPanel { Spacing = 12, Padding = new Thickness(12) };
        var dropContent = new StackPanel { Spacing = 8 };
        dropContent.Children.Add(preview);
        preview.Children.Add(emptyText);
        var addCurrent = new Button { Content = "Add Current Capture", HorizontalAlignment = HorizontalAlignment.Center, FontSize = 12 };
        addCurrent.Click += (_, _) =>
        {
            if (this.currentItem() is { IsVideo: false } i)
            {
                commit();
                Add(i.HasDocument ? i.DocumentPath : i.SharePath);
            }
        };
        dropContent.Children.Add(addCurrent);
        dropArea = new Border
        {
            Child = dropContent, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), MinHeight = 160,
            BorderThickness = new Thickness(1.5), BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(90, 128, 128, 128)),
            AllowDrop = true, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        dropArea.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems) && !e.DataView.Contains(StandardDataFormats.Text)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Add to Combine";
            dropArea.BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 0x7C, 0x3A, 0xED));
        };
        dropArea.DragLeave += (_, _) => dropArea.BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(90, 128, 128, 128));
        dropArea.Drop += async (_, e) =>
        {
            dropArea.BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(90, 128, 128, 128));
            commit(); // so a capture dragged from the strip includes unsaved edits
            foreach (var path in await EditorWindow.DroppedPaths(e.DataView)) Add(PreferDocument(path));
        };
        body.Children.Add(dropArea);
        list.ItemsSource = entries;
        entries.CollectionChanged += (_, _) => Refresh();
        list.RightTapped += (_, e) =>
        {
            if ((e.OriginalSource as FrameworkElement)?.DataContext is not Entry entry) return;
            var menu = new MenuFlyout();
            var remove = new MenuFlyoutItem { Text = "Remove", Icon = new FontIcon { Glyph = "\uE738" } };
            remove.Click += (_, _) => entries.Remove(entry);
            menu.Items.Add(remove);
            menu.ShowAt(list, e.GetPosition(list));
        };
        body.Children.Add(new TextBlock { Text = "Drag to reorder · right-click to remove", FontSize = 11, Opacity = 0.55 });
        body.Children.Add(list);
        BuildOptions(body);
        var scroller = new ScrollViewer { Content = body };
        SetRow(scroller, 1);
        Children.Add(scroller);

        var footer = new Grid { Padding = new Thickness(12), BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"] };
        clearButton.Click += (_, _) => entries.Clear();
        combineButton.HorizontalAlignment = HorizontalAlignment.Right;
        combineButton.Click += (_, _) => Combine();
        footer.Children.Add(clearButton);
        footer.Children.Add(combineButton);
        SetRow(footer, 2);
        Children.Add(footer);
        SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) DrawPreview(); };
        Refresh();
    }

    /// <summary>A capture's .rasternest (annotations included) when a PNG from the library is dropped.</summary>
    private static string PreferDocument(string path)
    {
        var doc = System.IO.Path.ChangeExtension(path, NestDocument.FileExtension);
        return path.EndsWith(".png", StringComparison.OrdinalIgnoreCase) && File.Exists(doc) ? doc : path;
    }

    public void Add(string path)
    {
        if (Flattened(path) is not { } f) return;
        using (f.Image)
        {
            var k = Math.Min(1, 360.0 / Math.Max(f.Image.Width, f.Image.Height));
            using var surface = SKSurface.Create(new SKImageInfo(Math.Max(1, (int)(f.Image.Width * k)), Math.Max(1, (int)(f.Image.Height * k))));
            surface.Canvas.DrawImage(f.Image, new SKRect(0, 0, surface.Canvas.DeviceClipBounds.Width, surface.Canvas.DeviceClipBounds.Height),
                                     new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
            using var thumb = surface.Snapshot();
            entries.Add(new Entry(path, System.IO.Path.GetFileNameWithoutExtension(path), thumb.Encode(SKEncodedImageFormat.Png, 100).ToArray(),
                                  new SizeD(f.Image.Width, f.Image.Height)));
        }
        Refresh();
    }

    /// <summary>A capture's rendered image (annotations and frame included), or any image file.</summary>
    private static (SKImage Image, double Scale)? Flattened(string path)
    {
        try
        {
            if (path.EndsWith("." + NestDocument.FileExtension, StringComparison.OrdinalIgnoreCase))
            {
                var (doc, bitmap) = ImageCodec.LoadDocument(path);
                using (bitmap) return (new AnnotationRenderer(doc.PixelScale).Flatten(bitmap, doc.Annotations, doc.Effects), doc.PixelScale);
            }
            if (ImageCodec.Load(path) is not { } l) return null;
            using (l.Bitmap) return (SKImage.FromBitmap(l.Bitmap.Copy()), l.Scale);
        }
        catch { return null; }
    }

    private CombineLayout Layout => new() { Arrangement = arrangement, Gap = gap, MatchSizes = matchSizes };

    private void BuildOptions(StackPanel body)
    {
        var layout = new RadioButtons { Header = "Layout", MaxColumns = 3 };
        foreach (var a in Enum.GetValues<CombineArrangement>()) layout.Items.Add(CombineLayout.Title(a));
        layout.SelectedIndex = (int)arrangement;
        layout.SelectionChanged += (_, _) => { arrangement = (CombineArrangement)Math.Max(0, layout.SelectedIndex); Refresh(); };
        body.Children.Add(layout);

        var gapTitle = new TextBlock { Text = $"Gap  {gap:0}", Opacity = 0.7 };
        var gapSlider = new Slider { Minimum = 0, Maximum = 120, Value = gap, StepFrequency = 1 };
        gapSlider.ValueChanged += (_, e) => { gap = e.NewValue; gapTitle.Text = $"Gap  {gap:0}"; Refresh(); };
        body.Children.Add(new StackPanel { Children = { gapTitle, gapSlider } });

        CheckBox Check(string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Content = text, IsChecked = value };
            c.Click += (_, _) => { set(c.IsChecked == true); Refresh(); };
            return c;
        }
        body.Children.Add(Check("Match sizes", matchSizes, v => matchSizes = v));
        body.Children.Add(Check("Transparent background", transparent, v => transparent = v));
        body.Children.Add(Check("Number each picture (1, 2, 3…)", numbered, v => numbered = v));
        body.Children.Add(new TextBlock
        {
            Text = "The result opens as a new capture. Each picture stays a separate layer you can move, resize or overlap.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.6,
        });
    }

    private void Refresh()
    {
        combineButton.IsEnabled = entries.Count >= 2;
        clearButton.IsEnabled = entries.Count > 0;
        DrawPreview();
        for (var i = 0; i < entries.Count; i++) entries[i].Number = (i + 1).ToString();
    }

    /// <summary>A miniature of the result using the real layout math.</summary>
    private void DrawPreview()
    {
        preview.Children.Clear();
        if (entries.Count == 0) { preview.Children.Add(emptyText); return; }
        var placed = Layout.Place(entries.Select(e => e.PixelSize).ToList());
        var availW = Math.Max(120, (ActualWidth > 0 ? ActualWidth : 260) - 46);
        const double availH = 140;
        var f = Math.Min(availW / Math.Max(placed.Canvas.Width, 1), availH / Math.Max(placed.Canvas.Height, 1));
        var canvas = new Canvas { Width = placed.Canvas.Width * f, Height = placed.Canvas.Height * f, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        canvas.Children.Add(new Rectangle
        {
            Width = canvas.Width, Height = canvas.Height,
            Fill = new SolidColorBrush(transparent ? Microsoft.UI.Colors.Transparent : Microsoft.UI.Colors.White),
            Stroke = new SolidColorBrush(global::Windows.UI.Color.FromArgb(80, 128, 128, 128)),
        });
        for (var i = 0; i < entries.Count; i++)
        {
            var r = placed.Frames[i];
            var image = new Image { Source = ToBitmap(entries[i].ThumbnailPng), Width = r.Width * f, Height = r.Height * f, Stretch = Stretch.Fill };
            Canvas.SetLeft(image, r.MinX * f);
            Canvas.SetTop(image, r.MinY * f);
            canvas.Children.Add(image);
            if (numbered)
            {
                var badge = new Border
                {
                    Width = 14, Height = 14, CornerRadius = new CornerRadius(7),
                    Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 240, 59, 51)),
                    Child = new TextBlock { Text = (i + 1).ToString(), FontSize = 8, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                                            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                };
                Canvas.SetLeft(badge, r.MinX * f + 3);
                Canvas.SetTop(badge, r.MinY * f + 3);
                canvas.Children.Add(badge);
            }
        }
        preview.Children.Add(canvas);
    }

    /// <summary>Lays the pictures out on a blank canvas as separate layers and adds that to the library.</summary>
    private void Combine()
    {
        var images = entries.Select(e => Flattened(e.Path)).OfType<(SKImage Image, double Scale)>().ToList();
        try
        {
            if (images.Count < 2) return;
            var scale = images.Max(i => i.Scale);
            var layout = Layout with { Gap = gap * scale };
            if (ImageCombiner.Layered(images, layout, transparent ? null : new Rgba(1, 1, 1), numbered) is not { } result) return;
            using (result.Canvas)
            {
                var item = CaptureLibrary.Shared.AddCapture(result.Canvas, result.Scale, result.Layers, name: "Combined " + CaptureNaming.TimestampedName()[11..]);
                created(item);
            }
        }
        finally { foreach (var (image, _) in images) image.Dispose(); }
    }

    private static BitmapImage ToBitmap(byte[] png)
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
}
