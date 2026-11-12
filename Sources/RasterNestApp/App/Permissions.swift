import AppKit
import RasterNestCapture
import RasterNestCore
import ScreenCaptureKit

@MainActor
enum Permissions {
    static var hasScreenCapture: Bool { MacScreenCapturer.hasPermission }

    /// True when ScreenCaptureKit will actually hand us screen content.
    static func screenCaptureKitWorks() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func presentScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "RasterNest needs Screen Recording permission"
        alert.informativeText = """
        Turn on RasterNest in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen RasterNest.

        Already switched on? That approval belongs to an older copy of RasterNest. Choose Reset Permission, then allow RasterNest again when macOS asks.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reset Permission")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess()
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            resetAndRequest()
        default:
            break
        }
    }

    /// Clears RasterNest's own Screen Recording entry (stale after a re-sign), asks macOS to prompt
    /// again, and relaunches so the new grant takes effect.
    static func resetAndRequest() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", Bundle.main.bundleIdentifier ?? RasterNestInfo.bundleIdentifier]
        try? reset.run()
        reset.waitUntilExit()

        CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()

        let alert = NSAlert()
        alert.messageText = "Allow RasterNest, then reopen it"
        alert.informativeText = "Switch RasterNest on in the list that just opened. Then click Reopen so macOS applies the change."
        alert.addButton(withTitle: "Reopen RasterNest")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
