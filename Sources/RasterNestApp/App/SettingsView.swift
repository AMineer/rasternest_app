import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        // The form scrolls; the window keeps whatever size it's given instead of growing to the
        // form's full height (which ran off the bottom of smaller screens).
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "RasterNest Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 560, height: 720))
        window.setFrameAutosaveName("RasterNestSettings")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        ActivationPolicy.becomeRegular()
        if let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            // Never taller than the screen; keep a saved size otherwise.
            var frame = window.frame
            if frame.height > visible.height - 40 {
                frame.size.height = visible.height - 40
                window.setFrame(frame, display: false)
            }
            if !visible.contains(window.frame) { window.center() }
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { ActivationPolicy.refresh() }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasPermission = Permissions.hasScreenCapture
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var autoCheck = Updater.shared.isAvailable ? Updater.shared.automaticallyChecks : true
    @State private var autoDownload = Updater.shared.isAvailable ? Updater.shared.automaticallyDownloads : false

    var body: some View {
        Form {
            Section("Shortcuts") {
                shortcutRow("Capture area or window", $settings.captureHotKey)
                shortcutRow("Capture full screen", $settings.fullScreenHotKey)
                shortcutRow("Scrolling capture", $settings.scrollingHotKey)
                shortcutRow("Record screen", $settings.recordHotKey)
                shortcutRow("Grab text (OCR)", $settings.textHotKey)
                Text("Click a shortcut and press new keys. ⌫ clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Selecting an area") {
                Toggle("Adjust the area before capturing", isOn: $settings.adjustBeforeCapture)
                Text("Drag the handles or use the arrow keys, then press Return. Turn off to capture as soon as you let go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include the mouse pointer in screenshots", isOn: $settings.captureCursor)
                Text("While selecting, press C to copy the color under the magnifier as hex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After capturing") {
                Toggle("Open in the editor", isOn: $settings.openEditor)
                Toggle("Copy to the clipboard", isOn: $settings.copyToClipboard)
                Toggle("Keep a PNG of each capture next to its editable file", isOn: $settings.keepPNG)
                    .help("RasterNest saves every capture to the captures folder. With this on, a PNG with your annotations sits beside each one and updates as you edit, ready to drop into docs.")
                HStack {
                    Text(settings.saveFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
            }

            Section("Screen recording") {
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Toggle("Show keystrokes in recordings", isOn: Binding(
                    get: { settings.showKeystrokes },
                    set: { on in
                        settings.showKeystrokes = on
                        if on && !KeystrokeOverlay.isPermitted { KeystrokeOverlay.requestPermission() }
                    }
                ))
                if settings.showKeystrokes {
                    Toggle("Include ordinary typing (not just shortcuts)", isOn: $settings.showAllTyping)
                        .padding(.leading, 18)
                    Text(KeystrokeOverlay.isPermitted
                         ? "Shortcuts and keys like Return or Esc appear at the bottom of the recording."
                         : "Needs Accessibility permission: System Settings › Privacy & Security › Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if #available(macOS 15.0, *) {
                    Toggle("Record microphone", isOn: $settings.recordMicrophone)
                    Toggle("Highlight mouse clicks", isOn: $settings.showClicks)
                } else {
                    Text("Microphone recording and click highlights need macOS 15 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { autoCheck },
                    set: { autoCheck = $0; Updater.shared.automaticallyChecks = $0 }
                ))
                Toggle("Download and install updates in the background", isOn: Binding(
                    get: { autoDownload },
                    set: { autoDownload = $0; Updater.shared.automaticallyDownloads = $0 }
                ))
                .disabled(!autoCheck)
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Updater.shared.checkForUpdates(nil) }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("RasterNest: launch at login failed: \(error)")
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                HStack {
                    Label(hasPermission ? "Screen Recording allowed" : "Screen Recording permission needed",
                          systemImage: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasPermission ? Color.green : Color.orange)
                    Spacer()
                    if !hasPermission {
                        Button("Open System Settings") {
                            CGRequestScreenCaptureAccess()
                            Permissions.openScreenRecordingSettings()
                        }
                    }
                    Button("Reset") { Permissions.resetAndRequest() }
                        .help("Clears RasterNest's Screen Recording approval and asks again. Use this if captures keep asking for permission even though RasterNest is switched on.")
                }
            }

            Section("Command line") {
                Text("`rnest` captures, records, annotates and combines from Terminal, and `rnest mcp` lets Claude and other AI agents use RasterNest. Homebrew installs it for you; with the DMG, use Install Command Line Tool below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Command Line Tool…") { CLIInstaller.run() }
            }
        }
        .formStyle(.grouped)
        .tint(Brand.violetColor)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = Permissions.hasScreenCapture
        }
    }

    private func shortcutRow(_ title: String, _ combo: Binding<HotKeyCombo?>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                HotKeyRecorder(combo: combo).frame(width: 150, height: 24)
                Button {
                    combo.wrappedValue = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Disable this shortcut")
                .opacity(combo.wrappedValue == nil ? 0 : 1)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
            CaptureLibrary.shared.reload()
        }
    }
}
