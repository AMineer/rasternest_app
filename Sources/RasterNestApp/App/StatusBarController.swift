import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let capture: CaptureCoordinator

    init(capture: CaptureCoordinator) {
        self.capture = capture
        super.init()
        if let button = item.button {
            button.image = Brand.menuBarImage()
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
        menu.addItem(withHotKey("Scrolling Capture", s.scrollingHotKey) { [weak self] in
            self?.capture.startScrolling(fromMenu: true)
        })
        menu.addItem(withHotKey("Record Screen", s.recordHotKey) { [weak self] in
            self?.capture.startRecording(fromMenu: true)
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

        let library = CaptureLibrary.shared
        library.reload()
        let recent = Array(library.items.prefix(8))
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for item in recent {
                let entry = ActionMenuItem(item.name) { EditorWindowController.show(item) }
                if let thumb = library.thumbnails[item.id]?.copy() as? NSImage {
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
        menu.addItem(ActionMenuItem("Check for Updates…") { Updater.shared.checkForUpdates(nil) })
        menu.addItem(ActionMenuItem("About RasterNest") { Brand.showAbout() })
        menu.addItem(ActionMenuItem("Install Command Line Tool…") { CLIInstaller.run() })
        menu.addItem(ActionMenuItem("Support RasterNest…") { Brand.openSponsor() })
        menu.addItem(ActionMenuItem("Quit RasterNest", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }

    private func withHotKey(_ title: String, _ combo: HotKeyCombo?, _ handler: @escaping () -> Void) -> NSMenuItem {
        ActionMenuItem(title, key: combo?.menuKeyEquivalent ?? "", modifiers: combo?.menuModifierMask ?? [], handler: handler)
    }
}
