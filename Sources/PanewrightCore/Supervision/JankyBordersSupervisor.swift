import Foundation

/// Supervises the JankyBorders daemon. A second `borders` invocation hands
/// its arguments to the running instance and exits, so "apply" is: update if
/// running, otherwise launch detached.
public struct JankyBordersSupervisor: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public static let defaultSearchPaths = [
        "/opt/homebrew/bin/borders",
        "/usr/local/bin/borders",
    ]

    public static func locate(fileManager: FileManager = .default) -> JankyBordersSupervisor? {
        for path in defaultSearchPaths where fileManager.isExecutableFile(atPath: path) {
            return JankyBordersSupervisor(executableURL: URL(filePath: path))
        }
        return nil
    }

    public func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", "borders"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func apply(arguments: [String]) throws {
        let updatingRunningDaemon = isRunning()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if updatingRunningDaemon {
            // Update invocation: hands settings to the daemon and exits fast.
            process.waitUntilExit()
        }
        // Otherwise this invocation *is* the daemon: leave it running detached.
    }

    public func stop() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pkill")
        process.arguments = ["-x", "borders"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
