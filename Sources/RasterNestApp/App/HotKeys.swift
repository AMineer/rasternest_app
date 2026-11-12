import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut (Carbon key code + modifiers).
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Display name of the main key ("C", "F13", "Space").
    var key: String

    var display: String { modifierSymbols + key }

    var modifierSymbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var menuKeyEquivalent: String { key.count == 1 ? key.lowercased() : "" }

    var menuModifierMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    static let defaultCapture = HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | shiftKey), key: "C")
    static let defaultFullScreen = HotKeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | shiftKey), key: "F")
    static let defaultText = HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | shiftKey), key: "T")

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19",
    ]

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        specialKeyNames[keyCode]?.hasPrefix("F") == true && specialKeyNames[keyCode]!.count > 1
    }
}

/// Registers system-wide hotkeys with Carbon (no Accessibility permission needed).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x524E_5354) /* 'RNST' */, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("RasterNest: could not register hotkey \(combo.display) (status \(status))")
            return false
        }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if err == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

// MARK: - Recorder control for Settings

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var combo: HotKeyCombo?

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.combo = combo
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.combo = combo
        view.onChange = { combo = $0 }
    }
}

final class HotKeyRecorderView: NSView {
    var combo: HotKeyCombo? { didSet { needsDisplay = true } }
    var onChange: ((HotKeyCombo?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        // Suspend global hotkeys so pressing an existing shortcut records it instead of firing it.
        HotKeyCenter.shared.unregisterAll()
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        NotificationCenter.default.post(name: AppSettings.hotKeysChanged, object: nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        let code = Int(event.keyCode)
        if code == kVK_Escape { window?.makeFirstResponder(nil); return }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let needsModifier = !HotKeyCombo.isFunctionKey(code)
        guard !needsModifier || !flags.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            return
        }
        let name = HotKeyCombo.specialKeyNames[code]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        onChange?(HotKeyCombo(keyCode: UInt32(code), modifiers: HotKeyCombo.carbonModifiers(flags), key: name))
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Capture ⌘-shortcuts while recording instead of letting menus eat them.
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "Type shortcut…" : (combo?.display ?? "Click to record")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: combo == nil || recording ? .regular : .medium),
            .foregroundColor: combo == nil || recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
