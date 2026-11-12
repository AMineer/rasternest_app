import AppKit
import RasterNestCapture

@MainActor
enum Permissions {
    static var hasScreenCapture: Bool { MacScreenCapturer.hasPermission }

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
        To capture your screen, turn on RasterNest in System Settings › Privacy & Security › \
        Screen & System Audio Recording. macOS may ask you to reopen RasterNest afterwards.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reopen RasterNest")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess()
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
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
