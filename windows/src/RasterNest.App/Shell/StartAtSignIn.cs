using Microsoft.Win32;

namespace RasterNest.App.Shell;

/// <summary>
/// "Start RasterNest when you sign in". The installed (MSIX) app uses its StartupTask, which also shows in
/// Task Manager › Startup apps; a development build falls back to the per-user Run key.
/// </summary>
internal static class StartAtSignIn
{
    private const string TaskId = "RasterNestStartup";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool IsPackaged
    {
        get
        {
            try { return global::Windows.ApplicationModel.Package.Current != null; }
            catch { return false; }
        }
    }

    public static async Task<bool> IsEnabledAsync()
    {
        if (IsPackaged)
        {
            var task = await global::Windows.ApplicationModel.StartupTask.GetAsync(TaskId);
            return task.State is global::Windows.ApplicationModel.StartupTaskState.Enabled
                or global::Windows.ApplicationModel.StartupTaskState.EnabledByPolicy;
        }
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("RasterNest") != null;
    }

    /// <summary>Returns a message when Windows won't allow the change (e.g. turned off in Task Manager).</summary>
    public static async Task<string?> SetAsync(bool enabled)
    {
        if (IsPackaged)
        {
            var task = await global::Windows.ApplicationModel.StartupTask.GetAsync(TaskId);
            if (!enabled) { task.Disable(); return null; }
            var state = await task.RequestEnableAsync();
            return state switch
            {
                global::Windows.ApplicationModel.StartupTaskState.Enabled or global::Windows.ApplicationModel.StartupTaskState.EnabledByPolicy => null,
                global::Windows.ApplicationModel.StartupTaskState.DisabledByUser =>
                    "Windows has RasterNest turned off in Task Manager › Startup apps. Turn it on there.",
                _ => "Windows didn't allow RasterNest to start at sign-in (it may be blocked by policy).",
            };
        }
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue("RasterNest", $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue("RasterNest", throwOnMissingValue: false);
        return null;
    }
}
