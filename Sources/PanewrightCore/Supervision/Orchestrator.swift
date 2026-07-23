import Foundation

public struct PanewrightPaths: Sendable {
    public var panewrightConfigFile: URL
    public var aerospaceConfigFile: URL
    public var sketchybarConfigDirectory: URL

    public init(
        panewrightConfigFile: URL,
        aerospaceConfigFile: URL,
        sketchybarConfigDirectory: URL
    ) {
        self.panewrightConfigFile = panewrightConfigFile
        self.aerospaceConfigFile = aerospaceConfigFile
        self.sketchybarConfigDirectory = sketchybarConfigDirectory
    }

    public static func `default`(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PanewrightPaths {
        let config = home.appending(path: ".config")
        return PanewrightPaths(
            panewrightConfigFile: config.appending(path: "panewright/panewright.toml"),
            aerospaceConfigFile: config.appending(path: "aerospace/aerospace.toml"),
            sketchybarConfigDirectory: config.appending(path: "sketchybar"))
    }
}

public enum AeroSpaceStatus: Equatable, Sendable, CustomStringConvertible {
    case notInstalled
    case notRunning
    /// Running but its CLI server isn't answering — usually the Accessibility
    /// permission was granted (or revoked) after launch; a restart fixes it.
    case unresponsive
    case running

    public var description: String {
        switch self {
        case .notInstalled: "not installed"
        case .notRunning: "not running"
        case .unresponsive: "running but unresponsive (Accessibility permission?)"
        case .running: "running"
        }
    }
}

/// The supervision pipeline: Panewright config in, a configured and reloaded
/// AeroSpace out.
public struct Orchestrator: Sendable {
    public var paths: PanewrightPaths

    public init(paths: PanewrightPaths = .default()) {
        self.paths = paths
    }

    public static let defaultConfigTemplate = """
        # Panewright configuration — i3 mental model, TOML syntax.
        # Every key is optional; omitted keys use i3-familiar defaults
        # (workspaces 1-9, hjkl focus/move, $mod+r resize, $mod+g join).

        modifier = "hyper"  # or "alt" / "cmd"
        """ + "\n"

    /// First-run: create `panewright.toml` so the user has something to edit.
    @discardableResult
    public func writeDefaultConfigIfMissing() throws -> Bool {
        let file = paths.panewrightConfigFile
        if FileManager.default.fileExists(atPath: file.path) {
            return false
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.defaultConfigTemplate.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// A missing config file means pure defaults; a malformed one is an error.
    public func loadConfig() throws -> PanewrightConfig {
        guard FileManager.default.fileExists(atPath: paths.panewrightConfigFile.path) else {
            return .default
        }
        let toml = try String(contentsOf: paths.panewrightConfigFile, encoding: .utf8)
        return try ConfigParser.parse(toml: toml)
    }

    /// Parse → emit → write. Returns the emitted AeroSpace TOML.
    @discardableResult
    public func writeAerospaceConfig() throws -> String {
        let emitted = AeroSpaceConfigEmitter.emit(try loadConfig())
        let file = paths.aerospaceConfigFile
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try emitted.write(to: file, atomically: true, encoding: .utf8)
        return emitted
    }

    /// Full pipeline: regenerate the AeroSpace config, hot-reload it if
    /// AeroSpace is up, and sync the JankyBorders daemon.
    public func apply() throws {
        let config = try loadConfig()
        try writeAerospaceConfig()
        if status() == .running, let cli = AeroSpaceCLI.locate() {
            try cli.run(["reload-config"])
        }
        try applyBorders(config)
        try applyBar(config)
    }

    /// Like borders: a missing binary is fine, bad config is not.
    public func applyBar(_ config: PanewrightConfig) throws {
        guard let bar = SketchyBarSupervisor.locate() else { return }
        if config.statusBar.enabled {
            try writeSketchyBarConfig(config)
            if bar.isRunning() {
                try bar.reload()
            } else {
                try bar.launch()
            }
        } else if bar.isRunning() {
            bar.stop()
        }
    }

    func writeSketchyBarConfig(_ config: PanewrightConfig) throws {
        let files = try SketchyBarConfigEmitter.emit(config)
        let directory = paths.sketchybarConfigDirectory
        let plugins = directory.appending(path: "plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let scripts: [(String, String)] = [
            ("sketchybarrc", files.sketchybarrc),
            ("plugins/panewright_workspaces.sh", files.workspacesPlugin),
            ("plugins/panewright_mode.sh", files.modePlugin),
            ("plugins/panewright_front_app.sh", files.frontAppPlugin),
            ("plugins/panewright_clock.sh", files.clockPlugin),
        ]
        for (name, content) in scripts {
            let url = directory.appending(path: name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    public func barInfo() -> String {
        guard let bar = SketchyBarSupervisor.locate() else {
            return "not installed"
        }
        return bar.isRunning() ? "on" : "off"
    }

    public func setBarEnabled(_ enabled: Bool) throws {
        try writeDefaultConfigIfMissing()
        let url = paths.panewrightConfigFile
        let text = try String(contentsOf: url, encoding: .utf8)
        try Self.settingEnabled(enabled, section: "bar", in: text)
            .write(to: url, atomically: true, encoding: .utf8)
        try apply()
    }

    /// Borders are an optional visual layer: a missing binary is not an
    /// error, but bad config is (caught upstream at parse time).
    public func applyBorders(_ config: PanewrightConfig) throws {
        guard let borders = JankyBordersSupervisor.locate() else { return }
        if config.focusBorder.enabled {
            try borders.apply(
                arguments: JankyBordersEmitter.arguments(for: config.focusBorder))
        } else if borders.isRunning() {
            borders.stop()
        }
    }

    /// UI-driven toggle: surgically edits `[border] enabled` in the user's
    /// panewright.toml (preserving comments), then applies.
    public func setBordersEnabled(_ enabled: Bool) throws {
        try writeDefaultConfigIfMissing()
        let url = paths.panewrightConfigFile
        let text = try String(contentsOf: url, encoding: .utf8)
        try Self.settingEnabled(enabled, section: "border", in: text)
            .write(to: url, atomically: true, encoding: .utf8)
        try apply()
    }

    static func settingEnabled(_ enabled: Bool, section: String, in toml: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        let headerIndex = lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "[\(section)]"
        }
        guard let headerIndex else {
            var result = toml
            if !result.hasSuffix("\n") { result += "\n" }
            return result + "\n[\(section)]\nenabled = \(enabled)\n"
        }
        var index = headerIndex + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                break
            }
            if trimmed.hasPrefix("enabled") {
                lines[index] = "enabled = \(enabled)"
                return lines.joined(separator: "\n")
            }
            index += 1
        }
        lines.insert("enabled = \(enabled)", at: headerIndex + 1)
        return lines.joined(separator: "\n")
    }

    public func bordersInfo() -> String {
        guard let borders = JankyBordersSupervisor.locate() else {
            return "not installed"
        }
        return borders.isRunning() ? "on" : "off"
    }

    public func status() -> AeroSpaceStatus {
        guard let cli = AeroSpaceCLI.locate() else {
            return .notInstalled
        }
        guard isAeroSpaceProcessRunning() else {
            return .notRunning
        }
        guard (try? cli.run(["list-workspaces", "--focused"])) != nil else {
            return .unresponsive
        }
        return .running
    }

    public func launchAeroSpace() throws {
        try runTool("/usr/bin/open", ["-a", "AeroSpace"])
    }

    /// Accessibility grants only take effect at app launch, so "grant, then
    /// restart AeroSpace" is the canonical permission-onboarding step.
    public func restartAeroSpace() throws {
        try runTool("/usr/bin/pkill", ["-x", "AeroSpace"])
        Thread.sleep(forTimeInterval: 0.5)
        try launchAeroSpace()
    }

    func isAeroSpaceProcessRunning() -> Bool {
        (try? runTool("/usr/bin/pgrep", ["-x", "AeroSpace"])) != nil
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AeroSpaceCLIError(
                arguments: [path] + arguments,
                exitCode: process.terminationStatus,
                output: "")
        }
    }
}
