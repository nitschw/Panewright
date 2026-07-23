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

        modifier = "ctrl-cmd"  # or "hyper" (Caps Lock via Karabiner) / "alt" / "cmd" / "ctrl" / "leader"
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

    /// The editor's save path: serialize a config model over panewright.toml.
    /// Note: rewrites the file — hand-written comments are replaced.
    public func writeConfig(_ config: PanewrightConfig) throws {
        let toml = PanewrightConfigSerializer.emit(config)
        try FileManager.default.createDirectory(
            at: paths.panewrightConfigFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try toml.write(to: paths.panewrightConfigFile, atomically: true, encoding: .utf8)
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

    /// Cold start: purge every managed process, then bring the whole
    /// environment up fresh. Deterministic regardless of how the last
    /// session ended (clean quit, crash, or kill). Blocking — callers run
    /// it off the main thread.
    public func bootstrap() {
        teardown()
        Thread.sleep(forTimeInterval: 0.7)
        guard AeroSpaceCLI.locate() != nil else {
            // No engine installed: still sync the visual layer.
            try? apply()
            return
        }
        try? launchAeroSpace()
        _ = waitForAeroSpace()
        try? apply()
        healLayoutsWhenReady()
    }

    /// Polls until the engine's CLI answers (it needs a moment after launch).
    @discardableResult
    public func waitForAeroSpace(timeout: TimeInterval = 15) -> Bool {
        guard let cli = AeroSpaceCLI.locate() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? cli.run(["list-workspaces", "--focused"])) != nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Quitting Panewright restores pre-existing macOS behavior: the border
    /// and bar daemons stop, every parked window is brought back on-screen
    /// (`enable off` — AeroSpace does NOT un-park on termination), and the
    /// tiling engine exits. Launch Panewright again and everything
    /// reassembles.
    public func teardown() {
        if let borders = JankyBordersSupervisor.locate(), borders.isRunning() {
            borders.stop()
        }
        if let bar = SketchyBarSupervisor.locate(), bar.isRunning() {
            bar.stop()
        }
        if let cli = AeroSpaceCLI.locate() {
            try? cli.run(["enable", "off"])
            Thread.sleep(forTimeInterval: 0.5)
        }
        try? runTool("/usr/bin/pkill", ["-x", "AeroSpace"])
    }

    /// Generated helper scripts: keybindings can't branch, scripts can — and
    /// the workspace-change dispatch is where user hooks plug in.
    func writeSupportScripts(_ config: PanewrightConfig) throws {
        let directory = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: "scripts")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var dispatch = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # Runs on every workspace switch (AeroSpace exec-on-workspace-change).
            /opt/homebrew/bin/sketchybar --trigger aerospace_workspace_change \\
              FOCUSED_WORKSPACE="$AEROSPACE_FOCUSED_WORKSPACE" 2>/dev/null
            """
        if let hook = config.workspaceChangedHook {
            dispatch += """


                # User hook from [hooks] workspace-changed:
                WORKSPACE="$AEROSPACE_FOCUSED_WORKSPACE" \\
                PREV_WORKSPACE="$AEROSPACE_PREV_WORKSPACE" \\
                \(hook)
                """
        }
        let dispatchURL = directory.appending(path: "on-workspace-change.sh")
        try (dispatch + "\n").write(to: dispatchURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dispatchURL.path)
        let script = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # i3 'scratchpad show': summon the first window stashed on the
            # hidden S workspace, floating, onto the focused workspace.
            A=/opt/homebrew/bin/aerospace
            FOCUSED_WS="$($A list-workspaces --focused)"
            WIN="$($A list-windows --workspace S --format '%{window-id}' 2>/dev/null | head -1 | awk '{print $1}')"
            if [ -n "$WIN" ]; then
              $A move-node-to-workspace --window-id "$WIN" "$FOCUSED_WS"
              $A layout --window-id "$WIN" floating
              $A focus --window-id "$WIN"
            else
              # Empty stash must not be a silent no-op.
              osascript -e 'display notification "Nothing stashed — use $mod+Shift+minus to stash the focused window." with title "Scratchpad is empty"' 2>/dev/null
            fi
            """
        let url = directory.appending(path: "scratchpad-show.sh")
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)

        // To-do list: plain-text storage so the list outlives any process,
        // and awk-only editing so the scripts need nothing installed.
        // The bar popup can't draw a two-field form, so both scripts just
        // hand off to the app's native editor via its URL scheme.
        let todoAdd = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            open "panewright://todo/add"
            """

        let todoEdit = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # $1 = 1-based row from the bar popup; the app takes 0-based.
            N="${1:-1}"
            open "panewright://todo/edit/$((N - 1))"
            """

        for (name, content) in [("todo-add.sh", todoAdd), ("todo-edit.sh", todoEdit)] {
            let url = directory.appending(path: name)
            try (content + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // The list itself persists independently of every process.
        let todoFile = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: "todo.txt")
        if !FileManager.default.fileExists(atPath: todoFile.path) {
            try "".write(to: todoFile, atomically: true, encoding: .utf8)
        }
    }

    /// Full pipeline: regenerate the AeroSpace config, hot-reload it if
    /// AeroSpace is up, and sync the JankyBorders daemon.
    public func apply() throws {
        let config = try loadConfig()
        try writeSupportScripts(config)
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
            ("plugins/panewright_todo.sh", files.todoPlugin),
            ("plugins/panewright_integrations.sh", files.integrationsPlugin),
            ("plugins/panewright_reorder.sh", files.reorderPlugin),
        ]
        for obsolete in ["panewright_clock.sh", "panewright_battery.sh", "panewright_wifi.sh"] {
            try? FileManager.default.removeItem(
                at: plugins.appending(path: obsolete))
        }
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

    /// One bar at a time: enabling Panewright's bar hides the macOS menu bar
    /// (auto-hide — it still slides in on hover for app menus and third-party
    /// status items); disabling restores it. No-ops unless the state changes.
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

    // MARK: Profiles — named saved configs, switchable from the menu.

    public var profilesDirectory: URL {
        paths.panewrightConfigFile.deletingLastPathComponent().appending(path: "profiles")
    }

    public func listProfiles() -> [String] {
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                atPath: profilesDirectory.path)
        else {
            return []
        }
        return items.filter { $0.hasSuffix(".toml") }
            .map { String($0.dropLast(".toml".count)) }
            .sorted()
    }

    public func saveProfile(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw ConfigError.invalidProfileName(name)
        }
        try writeDefaultConfigIfMissing()
        try FileManager.default.createDirectory(
            at: profilesDirectory, withIntermediateDirectories: true)
        let current = try String(contentsOf: paths.panewrightConfigFile, encoding: .utf8)
        try current.write(
            to: profilesDirectory.appending(path: "\(trimmed).toml"),
            atomically: true, encoding: .utf8)
    }

    public func activateProfile(named name: String) throws {
        let url = profilesDirectory.appending(path: "\(name).toml")
        let toml = try String(contentsOf: url, encoding: .utf8)
        // Validate before clobbering the live config.
        _ = try ConfigParser.parse(toml: toml)
        try toml.write(to: paths.panewrightConfigFile, atomically: true, encoding: .utf8)
        try apply()
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

    /// Restarts scramble workspace tree roots (the accordion surprise).
    /// Once the server answers, force every root back to horizontal tiles.
    /// Blocking — callers run it off the main thread.
    public func healLayoutsWhenReady() {
        guard let cli = AeroSpaceCLI.locate() else { return }
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.5)
            guard let output = try? cli.run(["list-workspaces", "--all"]) else {
                continue
            }
            for workspace in output.split(separator: "\n") {
                try? cli.run([
                    "layout", "--workspace", String(workspace), "--root", "h_tiles",
                ])
            }
            return
        }
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
