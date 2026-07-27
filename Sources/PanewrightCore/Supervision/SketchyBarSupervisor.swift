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

    /// Adjust the running bar's geometry in place — no reload, so the items
    /// keep their state and nothing visibly repopulates. A reload is the right
    /// tool when the *contents* changed; for a Dock move only the frame did.
    public func setBarGeometry(yOffset: Int, margin: Int? = nil) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments =
            ["--bar", "y_offset=\(yOffset)"] + (margin.map { ["margin=\($0)"] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// The y_offset the bar is currently configured with — needed alongside a
    /// measured frame to learn what one unit of y_offset actually moves.
    public func queryBarYOffset() -> Int? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--query", "bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let offset = json["y_offset"] as? Int
        else { return nil }
        return offset
    }

    /// Show/hide the whole bar in place — the auto-hide feature's verb.
    public func setHidden(_ hidden: Bool) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--bar", "hidden=\(hidden ? "on" : "off")"]
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
