import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Shows pressed keys as bubbles at the bottom of a recording area, so they appear in the video.
///
/// By default only shortcuts (keys with ⌘, ⌃ or ⌥) and special keys (Return, Tab, Esc, arrows…)
/// are shown, never ordinary typing, so passwords can't leak into a recording.
@MainActor
final class KeystrokeOverlay {
    /// macOS needs Accessibility permission to observe keys pressed in other apps.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) that leads to Accessibility settings.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    let panel: NSPanel
    private let model = KeystrokeModel()
    private var monitors: [Any] = []
    private let showAllTyping: Bool

    init(regionInScreen r: CGRect, showAllTyping: Bool) {
        self.showAllTyping = showAllTyping
        let height: CGFloat = 120
        let frame = CGRect(x: r.minX, y: r.minY + 16, width: r.width, height: min(height, r.height))
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: KeystrokeBubbles(model: model))
    }

    func show() {
        panel.orderFrontRegardless()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in handler(event); return event }) {
            monitors.append(local)
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }

    private func handle(_ event: NSEvent) {
        guard let label = Self.label(for: event, showAllTyping: showAllTyping) else { return }
        model.push(label, isTyping: !Self.isShortcut(event) && !Self.isSpecial(event))
    }

    static func isShortcut(_ e: NSEvent) -> Bool {
        !e.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    static func isSpecial(_ e: NSEvent) -> Bool {
        specialNames[Int(e.keyCode)] != nil
    }

    static let specialNames: [Int: String] = [
        kVK_Return: "Return ↩", kVK_ANSI_KeypadEnter: "Enter ⌤", kVK_Tab: "Tab ⇥", kVK_Escape: "Esc",
        kVK_Delete: "Delete ⌫", kVK_ForwardDelete: "⌦", kVK_Space: "Space",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// "⌃⌥⇧⌘K", "Return ↩", or (only when allowed) the typed character.
    static func label(for e: NSEvent, showAllTyping: Bool) -> String? {
        let flags = e.modifierFlags
        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option) { mods += "⌥" }
        if flags.contains(.shift) { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }
        let shortcut = isShortcut(e)
        if let special = specialNames[Int(e.keyCode)] {
            return mods + special
        }
        let key = (e.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        if shortcut { return mods + key }
        guard showAllTyping else { return nil }
        return e.characters
    }
}

@MainActor
private final class KeystrokeModel: ObservableObject {
    struct Entry: Identifiable { let id = UUID(); var text: String; var typing: Bool }
    @Published var entries: [Entry] = []
    private var clearTask: Task<Void, Never>?

    func push(_ text: String, isTyping: Bool) {
        // Consecutive typed characters join into one bubble.
        if isTyping, var last = entries.last, last.typing, last.text.count < 40 {
            last.text += text
            entries[entries.count - 1] = last
        } else {
            entries.append(Entry(text: text, typing: isTyping))
            if entries.count > 3 { entries.removeFirst(entries.count - 3) }
        }
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.entries.removeAll() }
        }
    }
}

private struct KeystrokeBubbles: View {
    @ObservedObject var model: KeystrokeModel

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ForEach(model.entries) { entry in
                    Text(entry.text)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.78)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12)))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.2), value: model.entries.map(\.id))
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
    }
}
