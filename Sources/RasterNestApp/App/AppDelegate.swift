import AppKit
import RasterNestCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    let capture = CaptureCoordinator()
    private var statusBar: StatusBarController?
    private var hotKeyObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Handle rasternest://capture etc. (for Raycast, Alfred, Shortcuts, `open`).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        CaptureLibrary.shared.reload()
        Updater.shared.start()
        statusBar = StatusBarController(capture: capture)
        registerHotKeys()
        hotKeyObserver = NotificationCenter.default.addObserver(forName: AppSettings.hotKeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }

        let settings = AppSettings.shared
        if !settings.hasOnboarded {
            settings.hasOnboarded = true
            if !Permissions.hasScreenCapture {
                Permissions.presentScreenRecordingAlert()
            } else {
                HUD.show("RasterNest is in your menu bar · \(settings.captureHotKey?.display ?? "") to capture",
                         symbol: "viewfinder", duration: 3)
            }
        }
    }

    func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let s = AppSettings.shared
        if let combo = s.captureHotKey { center.register(combo) { [weak self] in self?.capture.startInteractive() } }
        if let combo = s.fullScreenHotKey { center.register(combo) { [weak self] in self?.capture.captureFullScreen() } }
        if let combo = s.textHotKey { center.register(combo) { [weak self] in self?.capture.startInteractive(mode: .text) } }
        if let combo = s.scrollingHotKey { center.register(combo) { [weak self] in self?.capture.startScrolling() } }
        if let combo = s.recordHotKey { center.register(combo) { [weak self] in self?.capture.startRecording() } }
        statusBar?.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        EditorWindowController.commitIfOpen()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { DocumentOpener.open(url) }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme == RasterNestInfo.urlScheme else { return }
        let delay = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "delay" })?.value ?? "") ?? 0
        switch url.host {
        case "capture": capture.startInteractive(delay: delay)
        case "fullscreen": capture.captureFullScreen()
        case "text": capture.startInteractive(mode: .text)
        case "record":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let rect = query.first(where: { $0.name == "rect" })?.value?.split(separator: ",").compactMap { Double($0) }
            let seconds = query.first(where: { $0.name == "seconds" })?.value.flatMap(Double.init)
            if let r = rect, r.count == 4 {
                capture.startRecording(globalRect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), seconds: seconds)
            } else {
                capture.startRecording()
            }
        case "scrolling":
            let rect = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "rect" })?.value?
                .split(separator: ",").compactMap { Double($0) }
            if let r = rect, r.count == 4 {
                capture.startScrolling(globalRect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
            } else {
                capture.startScrolling()
            }
        case "settings": SettingsWindowController.shared.show()
        case "check-updates": Updater.shared.checkForUpdates(nil)
        default: break
        }
    }

    // MARK: Menu actions (reach here through the responder chain)

    @objc func captureArea(_ sender: Any?) { capture.startInteractive(fromMenu: true) }
    @objc func captureFullScreen(_ sender: Any?) { capture.captureFullScreen(fromMenu: true) }
    @objc func grabText(_ sender: Any?) { capture.startInteractive(mode: .text, fromMenu: true) }
    @objc func captureScrolling(_ sender: Any?) { capture.startScrolling(fromMenu: true) }
    @objc func recordScreen(_ sender: Any?) { capture.startRecording(fromMenu: true) }
    @objc func newFromClipboard(_ sender: Any?) { DocumentOpener.openFromClipboard() }
    @objc func openDocument(_ sender: Any?) { DocumentOpener.presentOpenPanel() }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func showAbout(_ sender: Any?) { Brand.showAbout() }
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates(sender) }
}

/// The app lives in the menu bar; it shows in the Dock only while it has windows open.
@MainActor
enum ActivationPolicy {
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    static func refresh() {
        DispatchQueue.main.async {
            let hasWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            NSApp.setActivationPolicy(hasWindows ? .regular : .accessory)
        }
    }
}
