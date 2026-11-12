import Foundation
import RasterNestCore

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let hotKeysChanged = Notification.Name("RasterNest.hotKeysChanged")

    private enum Keys {
        static let openEditor = "openEditor"
        static let copyToClipboard = "copyToClipboard"
        static let keepPNG = "keepPNG"
        static let saveFolder = "saveFolder"
        static let captureHotKey = "hotKey.capture"
        static let fullScreenHotKey = "hotKey.fullScreen"
        static let textHotKey = "hotKey.text"
        static let scrollingHotKey = "hotKey.scrolling"
        static let recordHotKey = "hotKey.record"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let showClicks = "showClicks"
        static let adjustBeforeCapture = "adjustBeforeCapture"
        static let defaultFrame = "defaultFrame"
        static let hasOnboarded = "hasOnboarded"
    }

    private let defaults = UserDefaults.standard

    @Published var openEditor: Bool { didSet { defaults.set(openEditor, forKey: Keys.openEditor) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    @Published var keepPNG: Bool { didSet { defaults.set(keepPNG, forKey: Keys.keepPNG) } }
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) } }

    @Published var captureHotKey: HotKeyCombo? { didSet { store(captureHotKey, Keys.captureHotKey) } }
    @Published var fullScreenHotKey: HotKeyCombo? { didSet { store(fullScreenHotKey, Keys.fullScreenHotKey) } }
    @Published var textHotKey: HotKeyCombo? { didSet { store(textHotKey, Keys.textHotKey) } }
    @Published var scrollingHotKey: HotKeyCombo? { didSet { store(scrollingHotKey, Keys.scrollingHotKey) } }
    @Published var recordHotKey: HotKeyCombo? { didSet { store(recordHotKey, Keys.recordHotKey) } }
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: Keys.recordSystemAudio) } }
    @Published var recordMicrophone: Bool { didSet { defaults.set(recordMicrophone, forKey: Keys.recordMicrophone) } }
    @Published var showClicks: Bool { didSet { defaults.set(showClicks, forKey: Keys.showClicks) } }
    @Published var adjustBeforeCapture: Bool { didSet { defaults.set(adjustBeforeCapture, forKey: Keys.adjustBeforeCapture) } }

    /// Frame applied to new captures (in points; scaled per capture). nil = no frame.
    @Published var defaultFrame: CanvasEffects? {
        didSet {
            if let defaultFrame, let data = try? JSONEncoder().encode(defaultFrame) {
                defaults.set(data, forKey: Keys.defaultFrame)
            } else {
                defaults.removeObject(forKey: Keys.defaultFrame)
            }
        }
    }

    /// The default frame scaled to a capture's pixel density.
    func defaultEffects(scale: CGFloat) -> CanvasEffects {
        guard var e = defaultFrame else { return .none }
        e.padding *= scale
        e.cornerRadius *= scale
        e.borderWidth *= scale
        return e
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Keys.hasOnboarded) }
        set { defaults.set(newValue, forKey: Keys.hasOnboarded) }
    }

    private init() {
        defaults.register(defaults: [Keys.openEditor: true, Keys.copyToClipboard: true, Keys.keepPNG: true, Keys.showClicks: true, Keys.adjustBeforeCapture: true])
        openEditor = defaults.bool(forKey: Keys.openEditor)
        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        keepPNG = defaults.bool(forKey: Keys.keepPNG)
        saveFolder = defaults.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CaptureNaming.defaultCaptureFolder()
        captureHotKey = Self.loadCombo(Keys.captureHotKey, fallback: .defaultCapture)
        fullScreenHotKey = Self.loadCombo(Keys.fullScreenHotKey, fallback: .defaultFullScreen)
        textHotKey = Self.loadCombo(Keys.textHotKey, fallback: .defaultText)
        scrollingHotKey = Self.loadCombo(Keys.scrollingHotKey, fallback: .defaultScrolling)
        recordHotKey = Self.loadCombo(Keys.recordHotKey, fallback: .defaultRecord)
        recordSystemAudio = defaults.bool(forKey: Keys.recordSystemAudio)
        recordMicrophone = defaults.bool(forKey: Keys.recordMicrophone)
        showClicks = defaults.bool(forKey: Keys.showClicks)
        adjustBeforeCapture = defaults.bool(forKey: Keys.adjustBeforeCapture)
        defaultFrame = defaults.data(forKey: Keys.defaultFrame).flatMap { try? JSONDecoder().decode(CanvasEffects.self, from: $0) }
    }

    private func store(_ combo: HotKeyCombo?, _ key: String) {
        // Empty data = explicitly disabled; missing key = use the default.
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.hotKeysChanged, object: nil)
    }

    private static func loadCombo(_ key: String, fallback: HotKeyCombo) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return fallback }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(HotKeyCombo.self, from: data)) ?? fallback
    }
}
