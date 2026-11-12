import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let capture: CaptureCoordinator

    init(capture: CaptureCoordinator) {
        self.capture = capture
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "RasterNest")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "RasterNest"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func refresh() {
        if let menu = item.menu { menuNeedsUpdate(menu) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared

        menu.addItem(withHotKey("Capture Area or Window", s.captureHotKey) { [weak self] in
            self?.capture.startInteractive(fromMenu: true)
        })
        menu.addItem(withHotKey("Capture Full Screen", s.fullScreenHotKey) { [weak self] in
            self?.capture.captureFullScreen(fromMenu: true)
        })
        menu.addItem(withHotKey("Grab Text", s.textHotKey) { [weak self] in
            self?.capture.startInteractive(mode: .text, fromMenu: true)
        })

        let delayed = NSMenuItem(title: "Capture After Delay", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for seconds in [3, 5, 10] {
            delayMenu.addItem(ActionMenuItem("\(seconds) seconds") { [weak self] in
                self?.capture.startInteractive(delay: seconds)
            })
        }
        delayed.submenu = delayMenu
        menu.addItem(delayed)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("New from Clipboard") { DocumentOpener.openFromClipboard() })
        menu.addItem(ActionMenuItem("Open…") { DocumentOpener.presentOpenPanel() })

        let recent = ImageExport.recentCaptures()
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for url in recent {
                let entry = ActionMenuItem(url.deletingPathExtension().lastPathComponent) { DocumentOpener.open(url) }
                if let thumb = NSImage(contentsOf: url) {
                    thumb.size = NSSize(width: 32, height: 32 * thumb.size.height / max(thumb.size.width, 1))
                    entry.image = thumb
                }
                recentMenu.addItem(entry)
            }
        }
        recentMenu.addItem(.separator())
        recentMenu.addItem(ActionMenuItem("Show in Finder") {
            let folder = AppSettings.shared.saveFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        })
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", key: ",", modifiers: .command) { SettingsWindowController.shared.show() })
        menu.addItem(ActionMenuItem("About RasterNest") {
            ActivationPolicy.becomeRegular()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(ActionMenuItem("Quit RasterNest", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }

    private func withHotKey(_ title: String, _ combo: HotKeyCombo?, _ handler: @escaping () -> Void) -> NSMenuItem {
        ActionMenuItem(title, key: combo?.menuKeyEquivalent ?? "", modifiers: combo?.menuModifierMask ?? [], handler: handler)
    }
}
