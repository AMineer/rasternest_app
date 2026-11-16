using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using RasterNest.Core;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;
using static RasterNest.Windows.Native;

namespace RasterNest.Windows;

/// <summary>What to record.</summary>
public abstract record RecordTarget
{
    public sealed record Display(int? Index) : RecordTarget;
    public sealed record Area(RectD Rect) : RecordTarget;
    public sealed record Window(uint Id) : RecordTarget;
}

public sealed record RecorderOptions(int Fps = 30, bool ShowsCursor = true);

/// <summary>
/// Records a display, an area or one window to H.264 MP4 using Windows.Graphics.Capture (which keeps working when
/// the window is covered) and the encoder built into Windows. Static screens still produce a video of the full
/// length: the last frame repeats until something changes.
/// </summary>
public sealed class ScreenRecorder : IAsyncDisposable
{
    private readonly RecordTarget target;
    private readonly RecorderOptions options;
    private IDirect3DDevice? device;
    private GraphicsCaptureItem? item;
    private Direct3D11CaptureFramePool? pool;
    private GraphicsCaptureSession? session;
    private Task? transcodeTask;
    private MediaStreamSource? source;

    private readonly object gate = new();
    private byte[]? latest;            // BGRA, output size
    private int latestVersion;
    private bool stopping;
    private bool configured;
    private readonly TaskCompletionSource<(byte[] Pixels, int Width, int Height)> firstFrame = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private DateTime started;
    private long frameIndex;
    private RectD crop;                 // in captured-item pixels
    private SizeInt32 poolSize;

    /// <summary>
    /// Called with every video frame (BGRA, PixelSize, timestamp) on the encoder's thread, e.g. to write a GIF
    /// alongside the MP4. Keep it quick or hand the frame to another thread.
    /// </summary>
    public Action<byte[], TimeSpan>? FrameSink { get; set; }

    /// <summary>Output size in pixels (even numbers, as H.264 needs).</summary>
    public (int Width, int Height) PixelSize { get; private set; }
    public double Scale { get; private set; } = 1;

    public ScreenRecorder(RecordTarget target, RecorderOptions? options = null)
    {
        this.target = target;
        this.options = options ?? new RecorderOptions();
        EnsureDpiAware();
    }

    public static bool IsSupported => GraphicsCaptureSession.IsSupported();

    public async Task StartAsync(string mp4Path)
    {
        if (!IsSupported) throw new CaptureException("Screen recording needs Windows 10 version 1903 or later.");
        device = CreateDevice();
        (item, crop, Scale) = CreateItem(target);

        poolSize = item.Size;
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
        pool.FrameArrived += OnFrameArrived;
        session = pool.CreateCaptureSession(item);
        try { session.IsCursorCaptureEnabled = options.ShowsCursor; } catch { /* older Windows */ }
        try
        {
            // Windows 11: no yellow border around what's being recorded.
            await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
            session.IsBorderRequired = false;
        }
        catch { /* Windows 10 shows the border */ }
        session.StartCapture();

        // Size the video from the first real frame: some windows (Settings, other Store apps when maximized)
        // arrive with a blank band along the top that isn't part of the window.
        var first = await Task.WhenAny(firstFrame.Task, Task.Delay(3000)) == firstFrame.Task ? firstFrame.Task.Result : default;
        if (first.Pixels != null && target is RecordTarget.Window)
        {
            var dy = BlankTopRows(first.Pixels, first.Width, first.Height, (int)crop.X, (int)crop.Width, 16);
            if (dy > 0 && dy < crop.Height / 4) crop = new RectD(crop.X, crop.Y + dy, crop.Width, crop.Height - dy);
        }
        if (Environment.GetEnvironmentVariable("RNEST_DEBUG") != null)
            Console.Error.WriteLine($"[debug] item {item.Size.Width}x{item.Size.Height} crop {crop}");
        int w = (int)crop.Width & ~1, h = (int)crop.Height & ~1;
        if (w < 2 || h < 2) throw new CaptureException("The area to record is too small.");
        PixelSize = (w, h);
        lock (gate)
        {
            latest = first.Pixels != null ? Crop(first.Pixels, first.Width, first.Height) : new byte[w * h * 4];
            configured = true;
        }

        // Encoder: uncompressed BGRA frames in, H.264 MP4 out.
        var props = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)w, (uint)h);
        props.FrameRate.Numerator = (uint)options.Fps;
        props.FrameRate.Denominator = 1;
        source = new MediaStreamSource(new VideoStreamDescriptor(props)) { BufferTime = TimeSpan.Zero, CanSeek = false };
        source.Starting += (_, e) => e.Request.SetActualStartPosition(TimeSpan.Zero);
        source.SampleRequested += OnSampleRequested;

        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
        profile.Audio = null;
        profile.Video.Width = (uint)w;
        profile.Video.Height = (uint)h;
        profile.Video.FrameRate.Numerator = (uint)options.Fps;
        profile.Video.FrameRate.Denominator = 1;
        // Sharp text: generous bitrate for screen content (about 0.15 bits per pixel per frame).
        profile.Video.Bitrate = (uint)Math.Clamp(w * h * options.Fps * 0.15, 2_000_000, 40_000_000);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(mp4Path))!);
        var file = await StorageFile.GetFileFromPathAsync(await CreateEmpty(mp4Path));
        var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(source, stream, profile);
        if (!prepared.CanTranscode)
            throw new CaptureException($"Windows can't encode this video ({prepared.FailureReason}).");

        started = DateTime.UtcNow;
        transcodeTask = Task.Run(async () =>
        {
            try { await prepared.TranscodeAsync(); }
            finally { stream.Dispose(); }
        });
    }

    private static async Task<string> CreateEmpty(string path)
    {
        var full = Path.GetFullPath(path);
        await File.WriteAllBytesAsync(full, []);
        return full;
    }

    /// <summary>Stops, finishes the MP4 and returns its duration.</summary>
    public async Task<TimeSpan> StopAsync()
    {
        lock (gate) { stopping = true; Monitor.PulseAll(gate); }
        var elapsed = DateTime.UtcNow - started;
        session?.Dispose();
        pool?.Dispose();
        if (transcodeTask != null) await transcodeTask;
        return elapsed;
    }

    public async ValueTask DisposeAsync()
    {
        if (!stopping) await StopAsync();
    }

    // MARK: frames

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        using var frame = sender.TryGetNextFrame();
        if (frame == null) return;
        try
        {
            if (frame.ContentSize.Width != poolSize.Width || frame.ContentSize.Height != poolSize.Height)
            {
                // The window was resized: keep recording at the original size (top-left anchored).
                poolSize = frame.ContentSize;
                sender.Recreate(device!, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
            }
            using var bitmap = SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied).AsTask().GetAwaiter().GetResult();
            var full = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
            bitmap.CopyToBuffer(full.AsBuffer());
            bool ready;
            lock (gate) ready = configured;
            if (!ready) { firstFrame.TrySetResult((full, bitmap.PixelWidth, bitmap.PixelHeight)); return; }
            var output = Crop(full, bitmap.PixelWidth, bitmap.PixelHeight);
            lock (gate)
            {
                latest = output;
                latestVersion++;
                Monitor.PulseAll(gate);
            }
        }
        catch (Exception e) when (e is COMException or ObjectDisposedException) { /* closing down */ }
    }

    /// <summary>The recorded area of a full frame, at PixelSize (black where the frame is smaller).</summary>
    private byte[] Crop(byte[] full, int fw, int fh)
    {
        var (w, h) = PixelSize;
        var output = new byte[w * h * 4];
        int sx = (int)crop.X, sy = (int)crop.Y;
        var copyW = Math.Max(0, Math.Min(w, fw - sx));
        for (var y = 0; y < h && sy + y < fh; y++)
            System.Buffer.BlockCopy(full, ((sy + y) * fw + sx) * 4, output, y * w * 4, copyW * 4);
        return output;
    }

    private static int BlankTopRows(byte[] px, int fw, int fh, int x0, int width, int max)
    {
        for (var y = 0; y < Math.Min(fh, max); y++)
            for (var x = x0; x < Math.Min(fw, x0 + width); x += 3)
            {
                var i = (y * fw + x) * 4;
                if (px[i] != 0 || px[i + 1] != 0 || px[i + 2] != 0) return y;
            }
        return 0;
    }

    /// <summary>The encoder asks for frames as fast as it can; hand them out at real-time pace at a constant rate.</summary>
    private void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var due = TimeSpan.FromSeconds(frameIndex / (double)options.Fps);
        byte[]? frame;
        lock (gate)
        {
            while (!stopping && DateTime.UtcNow - started < due)
                Monitor.Wait(gate, due - (DateTime.UtcNow - started) is var wait && wait > TimeSpan.Zero ? wait : TimeSpan.FromMilliseconds(1));
            if (stopping && frameIndex > 0) { args.Request.Sample = null; return; }
            frame = latest;
        }
        // Uncompressed RGB is bottom-up for the Windows encoder: hand it the rows in reverse.
        var (w, h) = PixelSize;
        var stride = w * 4;
        var flipped = new byte[frame!.Length];
        for (var y = 0; y < h; y++) System.Buffer.BlockCopy(frame, y * stride, flipped, (h - 1 - y) * stride, stride);
        var sample = MediaStreamSample.CreateFromBuffer(flipped.AsBuffer(), due);
        sample.Duration = TimeSpan.FromSeconds(1.0 / options.Fps);
        args.Request.Sample = sample;
        frameIndex++;
        FrameSink?.Invoke(frame, due);
    }

    // MARK: setup

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
        IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
    }

    private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    private static GraphicsCaptureItem ItemForWindow(IntPtr hwnd)
    {
        var interop = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem").AsInterface<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemIid;
        var ptr = interop.CreateForWindow(hwnd, ref iid);
        try { return GraphicsCaptureItem.FromAbi(ptr); } finally { Marshal.Release(ptr); }
    }

    private static GraphicsCaptureItem ItemForMonitor(IntPtr monitor)
    {
        var interop = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem").AsInterface<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemIid;
        var ptr = interop.CreateForMonitor(monitor, ref iid);
        try { return GraphicsCaptureItem.FromAbi(ptr); } finally { Marshal.Release(ptr); }
    }

    private static (GraphicsCaptureItem Item, RectD Crop, double Scale) CreateItem(RecordTarget target)
    {
        switch (target)
        {
            case RecordTarget.Window w:
            {
                var hwnd = new IntPtr(w.Id);
                if (!IsWindow(hwnd)) throw new CaptureException($"There's no window {w.Id}. See `rnest windows`.");
                if (IsIconic(hwnd)) throw new CaptureException("That window is minimized. Restore it first.");
                var item = ItemForWindow(hwnd);
                var dpi = GetDpiForWindow(hwnd);
                var crop = new RectD(0, 0, item.Size.Width, item.Size.Height);
                if (IsZoomed(hwnd) && GetWindowRect(hwnd, out var outer) &&
                    DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT visible, Marshal.SizeOf<RECT>()) == 0)
                {
                    // Maximized windows hang over the top of the screen; skip the rows that are off screen.
                    var top = Math.Clamp(visible.Top - outer.Top, 0, item.Size.Height / 4);
                    crop = new RectD(0, top, item.Size.Width, Math.Min(item.Size.Height - top, visible.Height));
                }
                return (item, crop, dpi > 0 ? dpi / 96.0 : 1);
            }
            case RecordTarget.Area a:
            {
                // Record the monitor under the area's centre and crop to the area.
                var r = new RECT { Left = (int)a.Rect.MinX, Top = (int)a.Rect.MinY, Right = (int)a.Rect.MaxX, Bottom = (int)a.Rect.MaxY };
                var monitor = MonitorFromRect(ref r, MONITOR_DEFAULTTONEAREST);
                var d = ScreenCapture.Displays().FirstOrDefault(x => x.Id == (uint)monitor.ToInt64())
                        ?? throw new CaptureException("The area isn't on a display.");
                var local = new RectD(a.Rect.MinX - d.X, a.Rect.MinY - d.Y, a.Rect.Width, a.Rect.Height).Intersect(new RectD(0, 0, d.Width, d.Height));
                if (local.IsNull || local.IsEmpty) throw new CaptureException("The area to record is off screen.");
                return (ItemForMonitor(monitor), local, d.Scale);
            }
            case RecordTarget.Display disp:
            {
                var displays = ScreenCapture.Displays();
                var d = disp.Index is { } i ? displays.ElementAtOrDefault(i) ?? throw new CaptureException($"There's no display {i}. See `rnest displays`.")
                    : displays.FirstOrDefault() ?? throw new CaptureException("No display found. Recording needs a signed-in desktop session.");
                var item = ItemForMonitor(new IntPtr(d.Id));
                return (item, new RectD(0, 0, item.Size.Width, item.Size.Height), d.Scale);
            }
            default: throw new ArgumentOutOfRangeException(nameof(target));
        }
    }

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels,
                                                uint levels, uint sdkVersion, out IntPtr device, out int featureLevel, out IntPtr context);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    private static IDirect3DDevice CreateDevice()
    {
        const int hardware = 1, warp = 5;
        const uint bgraSupport = 0x20;
        var hr = D3D11CreateDevice(IntPtr.Zero, hardware, IntPtr.Zero, bgraSupport, IntPtr.Zero, 0, 7, out var d3d, out _, out var ctx);
        if (hr < 0) hr = D3D11CreateDevice(IntPtr.Zero, warp, IntPtr.Zero, bgraSupport, IntPtr.Zero, 0, 7, out d3d, out _, out ctx);
        if (hr < 0) throw new CaptureException($"Couldn't start Direct3D for recording (0x{hr:X8}).");
        try
        {
            var dxgiIid = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3d, ref dxgiIid, out var dxgi));
            try
            {
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
                try { return WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
                finally { Marshal.Release(inspectable); }
            }
            finally { Marshal.Release(dxgi); }
        }
        finally
        {
            Marshal.Release(d3d);
            if (ctx != IntPtr.Zero) Marshal.Release(ctx);
        }
    }
}
