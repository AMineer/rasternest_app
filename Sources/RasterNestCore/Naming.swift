import Foundation

public enum RasterNestInfo {
    /// Kept in sync with the VERSION file by `scripts/set-version.sh`.
    public static let version = "0.4.1"
    public static let name = "RasterNest"
    public static let cliName = "rnest"
    public static let bundleIdentifier = "app.rasternest.RasterNest"
    public static let urlScheme = "rasternest"
}

public enum CaptureNaming {
    /// "RasterNest 2026-11-11 at 21.50.12"
    public static func timestampedName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(RasterNestInfo.name) \(f.string(from: date))"
    }

    /// Default folder for saved captures: $XDG_PICTURES_DIR or ~/Pictures, plus /RasterNest.
    public static func defaultCaptureFolder() -> URL {
        let env = ProcessInfo.processInfo.environment
        let pictures: URL
        if let xdg = env["XDG_PICTURES_DIR"], !xdg.isEmpty {
            pictures = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        }
        return pictures.appendingPathComponent(RasterNestInfo.name, isDirectory: true)
    }
}
