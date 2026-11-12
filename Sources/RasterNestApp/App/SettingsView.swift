import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "RasterNest Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        ActivationPolicy.becomeRegular()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { ActivationPolicy.refresh() }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hasPermission = Permissions.hasScreenCapture
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                shortcutRow("Capture area or window", $settings.captureHotKey)
                shortcutRow("Capture full screen", $settings.fullScreenHotKey)
                shortcutRow("Grab text (OCR)", $settings.textHotKey)
                Text("Click a shortcut and press new keys. ⌫ clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After capturing") {
                Toggle("Open in the editor", isOn: $settings.openEditor)
                Toggle("Copy to the clipboard", isOn: $settings.copyToClipboard)
                Toggle("Save a copy to the captures folder", isOn: $settings.autoSave)
                HStack {
                    Text(settings.saveFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
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
                }
            }

            Section("Command line") {
                Text("Use `rnest capture`, `rnest ocr` and `rnest export` from Terminal. Installed with `brew install --cask rasternest`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
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
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url }
    }
}
