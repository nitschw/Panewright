import Foundation

public struct AeroSpaceCLIError: Error, CustomStringConvertible {
    public let arguments: [String]
    public let exitCode: Int32
    public let output: String

    public var description: String {
        "aerospace \(arguments.joined(separator: " ")) exited \(exitCode): \(output)"
    }
}

/// Thin wrapper around the `aerospace` command-line tool — Panewright's entire
/// control surface for the tiling engine.
public struct AeroSpaceCLI: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// The bundled CLI first: when the engine ships inside Panewright, the
    /// CLI beside it is version-locked to that engine, while whatever brew
    /// linked may be older, newer, or stock. Falling back to the brew paths
    /// keeps a bundle-less dev build working.
    public static var defaultSearchPaths: [String] {
        [
            Bundle.main.bundleURL
                .appending(path: "Contents/Helpers/aerospace-cli").path,
            "/opt/homebrew/bin/aerospace",
            "/usr/local/bin/aerospace",
        ]
    }

    public static func locate(fileManager: FileManager = .default) -> AeroSpaceCLI? {
        for path in defaultSearchPaths where fileManager.isExecutableFile(atPath: path) {
            return AeroSpaceCLI(executableURL: URL(filePath: path))
        }
        return nil
    }

    @discardableResult
    /// Bounded: a CLI call that hangs — the engine's socket half-dead
    /// mid-teardown answers connects and then says nothing — used to block
    /// its caller forever. Called from the main thread, that was the
    /// minutes-long beachball during an update. No child gets more than the
    /// timeout; a timeout is an error, never a hang.
    public func run(_ arguments: [String], timeout: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // Read after exit (the child is gone, so this drains and EOFs), and
        // close the handles explicitly — thousands of CLI calls a day must
        // not lean on deallocation timing for their file descriptors.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let output = String(decoding: data, as: UTF8.self)
        guard !timedOut else {
            throw AeroSpaceCLIError(
                arguments: arguments, exitCode: -1,
                output: "timed out after \(Int(timeout))s")
        }
        guard process.terminationStatus == 0 else {
            throw AeroSpaceCLIError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}
