import AppKit
import RasterNestCore

/// "Install Command Line Tool…": links the `rnest` bundled in the app into /usr/local/bin,
/// for people who installed from the DMG rather than Homebrew.
@MainActor
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/rnest"

    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rnest")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// An `rnest` already reachable from a login shell, other than our own link.
    static func existingInstall() -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin"] {
            let path = dir + "/rnest"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func run() {
        ActivationPolicy.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)

        guard let cli = bundledCLI else {
            alert("The command line tool isn't in this copy of RasterNest.",
                  "Install it with Homebrew instead:\n\nbrew trust amineer/tap && brew install amineer/tap/rnest")
            return
        }

        if let existing = existingInstall() {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: existing)) ?? existing
            if target == cli.path {
                alert("rnest is already installed.", "\(existing) points to this copy of RasterNest. Try `rnest --help` in Terminal.")
                return
            }
            if existing != linkPath {
                alert("rnest is already installed.", "Found at \(existing) (probably from Homebrew). Try `rnest --help` in Terminal.")
                return
            }
        }

        let confirm = NSAlert()
        confirm.messageText = "Install the rnest command line tool?"
        confirm.informativeText = """
        This links \(linkPath) to the copy inside RasterNest, so it stays up to date with the app. \
        macOS will ask for an administrator password.

        Afterwards, run `rnest --help` in Terminal. To let Claude and other AI agents use RasterNest, \
        run `claude mcp add rasternest -- rnest mcp`.
        """
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let command = "/bin/mkdir -p /usr/local/bin && /bin/ln -sf \(shellQuote(cli.path)) \(shellQuote(linkPath))"
        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            // -128: the user cancelled the password prompt.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return }
            alert("Couldn't install rnest.", (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error.")
            return
        }
        alert("rnest is installed.", "Open a new Terminal window and run `rnest --help`.")
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
