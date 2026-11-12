import Foundation
import RasterNestCore

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let hotKeysChanged = Notification.Name("RasterNest.hotKeysChanged")

    private enum Keys {
        static let openEditor = "openEditor"
        static let copyToClipboard = "copyToClipboard"
        static let autoSave = "autoSave"
        static let saveFolder = "saveFolder"
        static let captureHotKey = "hotKey.capture"
        static let fullScreenHotKey = "hotKey.fullScreen"
        static let textHotKey = "hotKey.text"
        static let hasOnboarded = "hasOnboarded"
    }

    private let defaults = UserDefaults.standard

    @Published var openEditor: Bool { didSet { defaults.set(openEditor, forKey: Keys.openEditor) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Keys.autoSave) } }
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) } }

    @Published var captureHotKey: HotKeyCombo? { didSet { store(captureHotKey, Keys.captureHotKey) } }
    @Published var fullScreenHotKey: HotKeyCombo? { didSet { store(fullScreenHotKey, Keys.fullScreenHotKey) } }
    @Published var textHotKey: HotKeyCombo? { didSet { store(textHotKey, Keys.textHotKey) } }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: Keys.hasOnboarded) }
        set { defaults.set(newValue, forKey: Keys.hasOnboarded) }
    }

    private init() {
        defaults.register(defaults: [Keys.openEditor: true, Keys.copyToClipboard: true, Keys.autoSave: true])
        openEditor = defaults.bool(forKey: Keys.openEditor)
        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        autoSave = defaults.bool(forKey: Keys.autoSave)
        saveFolder = defaults.string(forKey: Keys.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CaptureNaming.defaultCaptureFolder()
        captureHotKey = Self.loadCombo(Keys.captureHotKey, fallback: .defaultCapture)
        fullScreenHotKey = Self.loadCombo(Keys.fullScreenHotKey, fallback: .defaultFullScreen)
        textHotKey = Self.loadCombo(Keys.textHotKey, fallback: .defaultText)
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
