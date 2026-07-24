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
        // Distribution is driven from the app layer (MonitorMap) once the
        // display arrangement is known and AeroSpace has settled — running it
        // here races AeroSpace's own startup workspace auto-assignment.
    }

    /// Spreads workspaces across displays so every monitor owns at least one,
    /// instead of AeroSpace piling them on the main display and auto-inventing
    /// throwaway workspaces (10, 11, …) for the extras. Policy "one each, rest
    /// on primary": each non-primary monitor is handed one distinct workspace
    /// (the lowest not already claimed), and everything else stays home on the
    /// primary. Idempotent, so re-running on a display change pulls a workspace
    /// onto a freshly attached monitor and returns an unplugged monitor's
    /// workspaces to a surviving display.
    public func distributeWorkspaces(primaryMonitorID: Int? = nil) {
        guard let cli = AeroSpaceCLI.locate(),
            let monitorOut = try? cli.run(["list-monitors"])
        else { return }
        let monitorIDs = monitorOut.split(separator: "\n").compactMap { line -> Int? in
            Int(line.components(separatedBy: " | ")[0].trimmingCharacters(in: .whitespaces))
        }
        guard monitorIDs.count > 1 else { return }  // single display: nothing to spread

        let config = (try? loadConfig()) ?? .default
        let names = AeroSpaceConfigEmitter.workspaceNumbers(in: config.bindings).map(String.init)
        guard !names.isEmpty else { return }

        // Prefer the caller's true main display; fall back to the busiest one.
        let primary = (primaryMonitorID.flatMap { monitorIDs.contains($0) ? $0 : nil })
            ?? mainMonitorID(cli) ?? monitorIDs[0]
        let secondaries = monitorIDs.filter { $0 != primary }
        let persistent = Set(names)
        for (index, monitor) in secondaries.enumerated() where index < names.count {
            let workspace = names[index]
            try? cli.run(["move-workspace-to-monitor", "--workspace", workspace, "\(monitor)"])
            // AeroSpace auto-invents throwaway workspaces (10, 11, …) for extra
            // monitors and homes their windows there. Rehome those onto the
            // workspace we're assigning, so the monitor shows its real windows
            // instead of an empty pill — then that throwaway workspace vanishes.
            rehomeStrandedWindows(cli, onMonitor: monitor, to: workspace, keeping: persistent)
            try? cli.run(["focus-monitor", "\(monitor)"])
            try? cli.run(["workspace", workspace])
        }
        // Leave the user looking at the primary, not the last secondary we touched.
        try? cli.run(["focus-monitor", "\(primary)"])
    }

    /// Moves windows off any non-persistent (auto-created) workspace currently
    /// on `monitor` onto `workspace`, so a freshly-assigned monitor shows the
    /// windows AeroSpace stranded on a throwaway workspace rather than an empty
    /// one. Leaves persistent (named) workspaces untouched.
    private func rehomeStrandedWindows(
        _ cli: AeroSpaceCLI, onMonitor monitor: Int, to workspace: String, keeping persistent: Set<String>
    ) {
        guard let onMon = try? cli.run(["list-workspaces", "--monitor", "\(monitor)"]) else { return }
        let auto = onMon.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != workspace && !persistent.contains($0) }
        for source in auto {
            guard let wins = try? cli.run([
                "list-windows", "--workspace", source, "--format", "%{window-id}",
            ]) else { continue }
            for id in wins.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !id.isEmpty {
                try? cli.run(["move-node-to-workspace", "--window-id", id, workspace])
            }
        }
    }

    /// AeroSpace doesn't tag its main display, so infer it: the primary is the
    /// display AeroSpace homes workspaces on by default, i.e. the one owning the
    /// most workspaces. Stable across re-runs because "rest on primary" keeps it
    /// the majority owner.
    private func mainMonitorID(_ cli: AeroSpaceCLI) -> Int? {
        guard let monitorOut = try? cli.run(["list-monitors"]) else { return nil }
        let ids = monitorOut.split(separator: "\n").compactMap { line -> Int? in
            Int(line.components(separatedBy: " | ")[0].trimmingCharacters(in: .whitespaces))
        }
        var best: (id: Int, count: Int)?
        for id in ids {
            let count = (try? cli.run(["list-workspaces", "--monitor", "\(id)", "--empty", "no"]))?
                .split(separator: "\n").count ?? 0
            if best == nil || count > best!.count { best = (id, count) }
        }
        return best?.id
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
        setSystemMenuBarHidden(false)
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

        let workspaceNames = AeroSpaceConfigEmitter.workspaceNumbers(in: config.bindings)
            .map(String.init)
        var dispatch = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # Runs on every workspace switch (AeroSpace exec-on-workspace-change).
            A=/opt/homebrew/bin/aerospace

            # Summoning a workspace away can leave the vacated monitor on an
            # auto-invented workspace (10, 11, …) that has no bar pill. Land it
            # on a free persistent workspace instead. Guarded so the summon we
            # issue (which re-runs this script) finds nothing to fix and stops.
            PERSISTENT="\(workspaceNames.joined(separator: " "))"
            FIXED=0
            for MON in $("$A" list-monitors --format '%{monitor-id}' 2>/dev/null); do
              VIS=$("$A" list-workspaces --monitor "$MON" --visible 2>/dev/null | tr -d ' ')
              case " $PERSISTENT " in *" $VIS "*) continue ;; esac
              [ -z "$VIS" ] && continue
              # Visible workspace is auto-invented: summon the first persistent
              # workspace that is empty and not visible on any monitor.
              TAKEN=$("$A" list-workspaces --monitor all --visible 2>/dev/null | tr -d ' ')
              OCCUPIED=$("$A" list-workspaces --monitor all --empty no 2>/dev/null | tr -d ' ')
              for W in $PERSISTENT; do
                printf '%s\\n' "$TAKEN" | grep -qx "$W" && continue
                printf '%s\\n' "$OCCUPIED" | grep -qx "$W" && continue
                "$A" focus-monitor "$MON" 2>/dev/null
                "$A" summon-workspace "$W" 2>/dev/null
                FIXED=1
                break
              done
            done
            # Fixing a vacated monitor moved focus there; put it back on the
            # workspace the user actually switched to.
            if [ "$FIXED" = 1 ] && [ -n "$AEROSPACE_FOCUSED_WORKSPACE" ]; then
              "$A" workspace "$AEROSPACE_FOCUSED_WORKSPACE" 2>/dev/null
            fi

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

        if let hook = config.focusChangedHook {
            // Runs on every focus change. Resolve the focused window once and
            // hand the user's command FOCUSED_APP / FOCUSED_WINDOW_ID /
            // WORKSPACE, so their script doesn't have to shell out itself.
            let focusDispatch = """
                #!/bin/bash
                # Generated by Panewright — do not edit by hand.
                # Runs on every focus change (AeroSpace on-focus-changed).
                # Query state directly — on-focus-changed doesn't set the
                # AEROSPACE_* env vars that exec-on-workspace-change does.
                A=/opt/homebrew/bin/aerospace
                read -r FOCUSED_WINDOW_ID FOCUSED_APP <<<"$("$A" list-windows --focused \\
                  --format '%{window-id} %{app-name}' 2>/dev/null)"
                export WORKSPACE="$("$A" list-workspaces --focused 2>/dev/null)"
                export FOCUSED_APP FOCUSED_WINDOW_ID
                \(hook)
                """
            let focusURL = directory.appending(path: "on-focus-change.sh")
            try (focusDispatch + "\n").write(to: focusURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: focusURL.path)
        }
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

        // Window pills: park a window in the bar, peek at it, put it back.
        // Parked windows live on the hidden "P" workspace (letters never
        // appear in the bar), so they survive until you summon them.
        let pillWindow = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            A=/opt/homebrew/bin/aerospace
            PILLS="$HOME/.config/panewright/pills.tsv"
            touch "$PILLS"
            # AeroSpace doesn't expand \\t in format strings — it has a token.
            # $1 = window id (from a bar drop); default is the focused window.
            if [ -n "$1" ]; then
              LINE=$("$A" list-windows --all \\
                --format '%{window-id}%{tab}%{app-name}%{tab}%{window-title}' \\
                | awk -F'\\t' -v id="$1" '$1 + 0 == id + 0')
            else
              LINE=$("$A" list-windows --focused \\
                --format '%{window-id}%{tab}%{app-name}%{tab}%{window-title}')
            fi
            ID=$(printf '%s' "$LINE" | cut -f1 | tr -d ' ')
            [ -z "$ID" ] && exit 0
            awk -F'\\t' -v id="$ID" '$1 == id { found = 1 } END { exit !found }' "$PILLS" \\
              || printf '%s\\n' "$LINE" >> "$PILLS"
            "$A" layout --window-id "$ID" floating
            "$A" move-node-to-workspace --window-id "$ID" P
            sketchybar --trigger panewright_pills 2>/dev/null
            """

        let pillToggle = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            # $1 = window id. Parked -> summon it here; visible -> park it.
            A=/opt/homebrew/bin/aerospace
            PILLS="$HOME/.config/panewright/pills.tsv"
            ID="$1"
            [ -z "$ID" ] && exit 0
            if "$A" list-windows --workspace P --format '%{window-id}' 2>/dev/null \\
                | tr -d ' ' | grep -qx "$ID"; then
              WS=$("$A" list-workspaces --focused)
              "$A" move-node-to-workspace --window-id "$ID" "$WS"
              "$A" layout --window-id "$ID" floating
              "$A" focus --window-id "$ID"
            else
              "$A" layout --window-id "$ID" floating
              "$A" move-node-to-workspace --window-id "$ID" P
            fi
            sketchybar --trigger panewright_pills 2>/dev/null
            """

        let pillRelease = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            # $1 = window id. Return it to tiling and drop its pill.
            A=/opt/homebrew/bin/aerospace
            PILLS="$HOME/.config/panewright/pills.tsv"
            ID="$1"
            [ -z "$ID" ] && exit 0
            WS=$("$A" list-workspaces --focused)
            "$A" move-node-to-workspace --window-id "$ID" "$WS" 2>/dev/null
            "$A" layout --window-id "$ID" tiling 2>/dev/null
            TMP=$(mktemp)
            awk -F'\\t' -v id="$ID" '$1 != id' "$PILLS" > "$TMP" && mv "$TMP" "$PILLS"
            sketchybar --trigger panewright_pills 2>/dev/null
            """

        // Clicking a workspace number focuses that monitor and switches it —
        // only that monitor moves (i3-style per-monitor).
        let workspaceSelect = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            # $1 = sketchybar display, $2 = workspace.
            A=/opt/homebrew/bin/aerospace
            MAP="$HOME/.config/panewright/monitor-map.tsv"
            MON=$(awk -F'\\t' -v d="$1" '$1 == d { print $2 }' "$MAP" 2>/dev/null)
            [ -z "$MON" ] && MON="$1"
            "$A" focus-monitor "$MON" 2>/dev/null
            "$A" workspace "$2" 2>/dev/null
            """

        for (name, content) in [
            ("todo-add.sh", todoAdd), ("todo-edit.sh", todoEdit),
            ("pill-window.sh", pillWindow), ("pill-toggle.sh", pillToggle),
            ("pill-release.sh", pillRelease), ("workspace-select.sh", workspaceSelect),
        ] {
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
            // Bottom bar coexists with the native menu bar — no hiding.
            setSystemMenuBarHidden(false)
        } else {
            if bar.isRunning() {
                bar.stop()
            }
            setSystemMenuBarHidden(false)
        }
    }

    /// Toggle "Automatically hide and show the menu bar". Kicking Dock and
    /// SystemUIServer makes it take effect without a logout.
    func setSystemMenuBarHidden(_ hidden: Bool) {
        let current = runToolCapture(
            "/usr/bin/defaults", ["read", "NSGlobalDomain", "_HIHideMenuBar"])
        guard (current == "1") != hidden else { return }
        try? runTool(
            "/usr/bin/defaults",
            ["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", hidden ? "true" : "false"])
        try? runTool("/usr/bin/killall", ["SystemUIServer"])
        try? runTool("/usr/bin/killall", ["Dock"])
    }

    private func runToolCapture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
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
            ("plugins/panewright_pills.sh", files.pillsPlugin),
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

    /// True when AeroSpace is running yet manages **zero** windows while the
    /// system clearly has application windows on screen — the signature of a
    /// stalled Accessibility connection (macOS stops answering AeroSpace's AX
    /// queries; it survives a process restart and needs the permission
    /// re-granted). `visibleAppWindowCount` is the caller's independent count
    /// from CGWindowList, which needs no AX permission.
    public func aeroSpaceIsStalled(visibleAppWindowCount: Int) -> Bool {
        guard visibleAppWindowCount >= Self.stallWindowThreshold,
            let cli = AeroSpaceCLI.locate(),
            isAeroSpaceProcessRunning()
        else { return false }
        // A blank line still splits to one empty element; count real ids.
        let managed = (try? cli.run(["list-windows", "--all", "--format", "%{window-id}"]))?
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count ?? 0
        return managed == 0
    }

    /// Enough on-screen app windows that AeroSpace managing none of them can't
    /// be a legitimately empty desktop.
    static let stallWindowThreshold = 3

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
