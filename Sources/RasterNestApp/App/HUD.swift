import AppKit
import SwiftUI

/// Small floating toast / countdown that never takes focus.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        present(HUDView(text: message, symbol: symbol, big: false), centered: false)
        scheduleHide(after: duration)
    }

    /// Shows 3…2…1 then calls `completion` once the HUD is gone (so it never appears in the capture).
    static func countdown(seconds: Int, completion: @escaping () -> Void) {
        guard seconds > 0 else {
            hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: completion)
            return
        }
        hideWork?.cancel()
        present(HUDView(text: "\(seconds)", symbol: nil, big: true), centered: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            countdown(seconds: seconds - 1, completion: completion)
        }
    }

    static func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private static func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func present(_ view: HUDView, centered: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        let screen = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        let y = centered ? screen.midY - size.height / 2 : screen.minY + screen.height * 0.18
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: y))
        panel.orderFrontRegardless()
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String?
    let big: Bool

    var body: some View {
        Group {
            if big {
                Text(text)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 140, height: 140)
            } else {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol) }
                    Text(text)
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
            }
        }
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: big ? 28 : 14, style: .continuous).fill(Color.black.opacity(0.78)))
        .padding(4)
    }
}
