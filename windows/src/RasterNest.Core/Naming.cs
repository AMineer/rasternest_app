using System.Globalization;
using System.Reflection;

namespace RasterNest.Core;

public static class RasterNestInfo
{
    /// <summary>From the repo's VERSION file, via Directory.Build.props.</summary>
    public static string Version { get; } =
        typeof(RasterNestInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            .Split('+')[0] ?? "0.0.0";

    public const string Name = "RasterNest";
    public const string CliName = "rnest";
    public const string UrlScheme = "rasternest";
}

public static class CaptureNaming
{
    /// <summary>"RasterNest 2026-11-11 at 21.50.12"</summary>
    public static string TimestampedName(DateTime? date = null) =>
        $"{RasterNestInfo.Name} {(date ?? DateTime.Now).ToString("yyyy-MM-dd 'at' HH.mm.ss", CultureInfo.InvariantCulture)}";

    /// <summary>Default folder for saved captures: Pictures\RasterNest.</summary>
    public static string DefaultCaptureFolder()
    {
        var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        if (string.IsNullOrEmpty(pictures))
            pictures = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Pictures");
        return Path.Combine(pictures, RasterNestInfo.Name);
    }
}
