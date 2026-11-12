import AppKit

/// Programmatic main menu (no storyboard). Items target the responder chain.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        func item(_ title: String, _ action: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            top.submenu = menu
            return top
        }

        main.addItem(submenu("RasterNest", [
            item("About RasterNest", "showAbout:"),
            item("Check for Updates…", "checkForUpdates:"),
            .separator(),
            item("Settings…", "showSettings:", ","),
            .separator(),
            item("Hide RasterNest", "hide:", "h"),
            item("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            item("Show All", "unhideAllApplications:"),
            .separator(),
            item("Quit RasterNest", "terminate:", "q"),
        ]))

        main.addItem(submenu("File", [
            item("Capture Area or Window", "captureArea:"),
            item("Capture Full Screen", "captureFullScreen:"),
            item("Scrolling Capture", "captureScrolling:"),
            item("Record Screen", "recordScreen:"),
            item("Grab Text", "grabText:"),
            .separator(),
            item("New from Clipboard", "newFromClipboard:", "n"),
            item("Open…", "openDocument:", "o"),
            .separator(),
            item("Close", "performClose:", "w"),
            item("Save…", "saveDocument:", "s"),
            item("Save As…", "saveDocumentAs:", "s", [.command, .shift]),
            item("Export Image…", "exportImage:", "e"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "z", [.command, .shift]),
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            item("Delete", "delete:"),
            item("Select All", "selectAll:", "a"),
        ]))

        main.addItem(submenu("View", [
            item("Zoom In", "zoomIn:", "="),
            item("Zoom Out", "zoomOut:", "-"),
            item("Actual Size", "zoomActual:", "0"),
            item("Zoom to Fit", "zoomFit:", "9"),
        ]))

        let window = submenu("Window", [
            item("Minimize", "performMiniaturize:", "m"),
            item("Zoom", "performZoom:"),
        ])
        main.addItem(window)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window.submenu
    }
}
