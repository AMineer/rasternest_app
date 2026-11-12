import AppKit
import Sparkle

/// In-app updates via Sparkle. The feed (appcast.xml) is published with each GitHub release and
/// every update is checked against the EdDSA public key in Info.plist (SUPublicEDKey).
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// For testing an update flow against a local feed:
    /// `defaults write app.rasternest.RasterNest RasterNestUpdateFeedOverride file:///path/appcast.xml`
    nonisolated static let feedOverrideKey = "RasterNestUpdateFeedOverride"

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

    var updater: SPUUpdater { controller.updater }

    /// Sparkle only works from a real app bundle (not `swift run`).
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard isAvailable else { return }
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isAvailable else {
            HUD.show("Updates work in the installed app", symbol: "exclamationmark.circle")
            return
        }
        ActivationPolicy.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(sender)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Menu-bar apps get gentle reminders instead of a window popping up out of nowhere.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            ActivationPolicy.becomeRegular()
            if !state.userInitiated {
                HUD.show("RasterNest \(update.displayVersionString) is available", symbol: "arrow.down.circle.fill", duration: 3)
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { ActivationPolicy.refresh() }
    }
}
