import Foundation

/// Small helpers for running the external tools some backends rely on.
public enum Shell {
    public struct Output {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Absolute path of `name` on $PATH, if present.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs a tool and collects its output.
    ///
    /// Pass `captureOutput: false` for tools that fork a long-lived child holding the
    /// pipes open (e.g. `xclip`), otherwise reading to EOF would never return.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], stdin: Data? = nil,
                           captureOutput: Bool = true) throws -> Output {
        guard let executable = which(tool) else {
            throw CaptureFailure.noBackend("`\(tool)` was not found on PATH.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe()
        if captureOutput {
            process.standardOutput = outPipe
            process.standardError = errPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        try process.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        var out = Data()
        let errBox = DataBox()
        if captureOutput {
            // Drain stderr concurrently so a chatty tool can't block on a full pipe.
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.wait()
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: out,
                      stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    static func temporaryPNG() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rnest-\(UUID().uuidString).png")
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
