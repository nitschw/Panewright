import Foundation

/// Supervises the SketchyBar daemon: launch detached, hot-reload, stop.
public struct SketchyBarSupervisor: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public static let defaultSearchPaths = [
        "/opt/homebrew/bin/sketchybar",
        "/usr/local/bin/sketchybar",
    ]

    public static func locate(fileManager: FileManager = .default) -> SketchyBarSupervisor? {
        for path in defaultSearchPaths where fileManager.isExecutableFile(atPath: path) {
            return SketchyBarSupervisor(executableURL: URL(filePath: path))
        }
        return nil
    }

    public func isRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", "sketchybar"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func launch() throws {
        let process = Process()
        process.executableURL = executableURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The daemon stays running detached; config comes from sketchybarrc.
    }

    public func reload() throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--reload"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    public func stop() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pkill")
        process.arguments = ["-x", "sketchybar"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
