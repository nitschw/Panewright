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

        modifier = "alt"  # or "hyper" (Caps Lock via Karabiner) / "ctrl-cmd" / "cmd" / "ctrl" / "leader"
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
        // Someone may already be an AeroSpace user. Keep whatever is there
        // before replacing it — once, since our own output is recognizable.
        ConfigBackup.preserve(file, into: backupsDirectory)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try emitted.write(to: file, atomically: true, encoding: .utf8)
        return emitted
    }

    /// Cold start: purge every managed process, then bring the whole
    /// environment up fresh. Deterministic regardless of how the last
    /// session ended (clean quit, crash, or kill). Blocking — callers run
    /// it off the main thread.
    /// Keep ~/.config/panewright/bin/aerospace pointing at the CLI the app
    /// actually uses. Every generated script and plugin calls through this
    /// link, so the answer to "which aerospace binary" lives in exactly one
    /// place — a dozen scripts each hardcoding the brew path went stale the
    /// moment the CLI moved into the app bundle.
    func refreshCLILink() {
        guard let cli = AeroSpaceCLI.locate() else { return }
        let bin = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: "bin")
        let link = bin.appending(path: "aerospace")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            == cli.executableURL.path { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: cli.executableURL)
        // The panewright CLI too (menu, import…): generated scripts call it
        // through here so they never depend on brew's PATH being linked.
        let own = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/panewright-cli")
        let ownLink = bin.appending(path: "panewright")
        if FileManager.default.isExecutableFile(atPath: own.path) {
            try? FileManager.default.removeItem(at: ownLink)
            try? FileManager.default.createSymbolicLink(
                at: ownLink, withDestinationURL: own)
        }
    }

    /// Dock insets arrive as parameters because measuring them needs NSScreen
    /// and this layer has no AppKit — the caller reads them on the main actor
    /// before detaching.
    public func bootstrap(dockInsetBottom: Int = 0, dockInsetSides: Int = 0) {
        teardown()
        Thread.sleep(forTimeInterval: 0.7)
        guard AeroSpaceCLI.locate() != nil else {
            // No engine installed: still sync the visual layer.
            try? apply(dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
            return
        }
        try? launchAeroSpace()
        _ = waitForAeroSpace()
        try? apply(dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
        healLayoutsWhenReady()
        restoreWorkspaces()
        // Distribution is driven from the app layer (MonitorMap) once the
        // display arrangement is known and AeroSpace has settled — running it
        // here races AeroSpace's own startup workspace auto-assignment.
    }

    /// Spreads workspaces across displays so every monitor owns at least one,
    /// instead of AeroSpace piling them on the main display and auto-inventing
    /// throwaway workspaces (10, 11, …) for the extras.
    ///
    /// i3's rule, ported: a new output gets the lowest *unused* workspace.
    /// Taking `names[index]` instead — the lowest workspaces, occupied or not
    /// — is how plugging in a monitor stole workspace 0 with the user's
    /// windows on it and teleported them across the desk.
    ///
    /// Idempotent in the strong sense: a monitor already showing one of the
    /// user's real workspaces is left completely alone. Display-change
    /// notifications fire far more often than displays actually change, and a
    /// "re-spread" that moves anything on a no-op event reads as the window
    /// manager glitching. Focus is put back exactly where it was, and only if
    /// something moved at all.
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
        let persistent = Set(names)

        // Prefer the caller's true main display; fall back to the busiest one.
        let primary = (primaryMonitorID.flatMap { monitorIDs.contains($0) ? $0 : nil })
            ?? mainMonitorID(cli) ?? monitorIDs[0]
        let focusedBefore = (try? cli.run(["list-workspaces", "--focused"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Workspaces pinned to a monitor in the config are the engine's to
        // place (workspace-to-monitor-force-assignment); never second-guess.
        let pinned = Set(config.workspaceMonitors.keys.map(String.init))
        let empty = Set(
            ((try? cli.run(["list-workspaces", "--monitor", "all", "--empty"])) ?? "")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var assignable = names.filter { empty.contains($0) && !pinned.contains($0) }
        var moved = false
        for monitor in monitorIDs where monitor != primary {
            // Already showing one of the user's workspaces? Then it's set up,
            // whether by us, by the engine's force-assignments, or by hand.
            if let visible = try? cli.run([
                "list-workspaces", "--monitor", "\(monitor)", "--visible",
            ]),
                persistent.contains(visible.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                continue
            }
            guard !assignable.isEmpty else { continue }
            let workspace = assignable.removeFirst()
            try? cli.run(["move-workspace-to-monitor", "--workspace", workspace, "\(monitor)"])
            // AeroSpace auto-invents throwaway workspaces (10, 11, …) for extra
            // monitors and homes their windows there. Rehome those onto the
            // workspace we're assigning, so the monitor shows its real windows
            // instead of an empty pill — then that throwaway workspace vanishes.
            rehomeStrandedWindows(cli, onMonitor: monitor, to: workspace, keeping: persistent)
            try? cli.run(["focus-monitor", "\(monitor)"])
            try? cli.run(["workspace", workspace])
            moved = true
        }
        // Put focus back where the user had it — not on "the primary", which
        // is only right when that's where they happened to be looking.
        if moved, let focusedBefore, !focusedBefore.isEmpty {
            try? cli.run(["workspace", focusedBefore])
        }
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
        // The freshest possible record of who lives where, taken while the
        // engine can still answer — bootstrap restores it, so a Panewright
        // restart stops scrambling workspaces.
        snapshotWorkspaces()
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
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace

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
                A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
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
        // Fullscreen windows own an exclusive macOS space, so move commands
        // silently do nothing against them. Drop out, move, then restore — the
        // behavior users expect when sending a maximized app to another screen.
        let moveWindow = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # move-window.sh workspace <N> | monitor <target>
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
            KIND="$1"; TARGET="$2"
            [ -z "$TARGET" ] && exit 0
            read -r WID FS <<<"$("$A" list-windows --focused \\
              --format '%{window-id} %{window-is-fullscreen}' 2>/dev/null)"
            # A fullscreen window sits on its own macOS space, where AeroSpace
            # often reports no focused window — fall back to the fullscreen
            # window on the focused workspace so the move still lands.
            if [ -z "$WID" ]; then
              WS="$("$A" list-workspaces --focused 2>/dev/null)"
              read -r WID FS <<<"$("$A" list-windows --workspace "$WS" \\
                --format '%{window-id} %{window-is-fullscreen}' 2>/dev/null \\
                | awk '$2=="true"{print; exit}')"
            fi
            [ -z "$WID" ] && exit 0
            if [ "$FS" = "true" ]; then
              "$A" fullscreen off --window-id "$WID" 2>/dev/null
              sleep 0.15
            fi
            if [ "$KIND" = "monitor" ]; then
              "$A" move-node-to-monitor --wrap-around --window-id "$WID" "$TARGET" 2>/dev/null
            else
              "$A" move-node-to-workspace --window-id "$WID" "$TARGET" 2>/dev/null
            fi
            if [ "$FS" = "true" ]; then
              sleep 0.15
              "$A" fullscreen on --window-id "$WID" 2>/dev/null
            fi
            """
        // Mic mute needs to remember the pre-mute level, or unmuting would
        // guess. Stash it beside the config and restore on the way back up.
        let micToggle = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            STATE="$HOME/.config/panewright/.mic-level"
            LEVEL=$(osascript -e 'input volume of (get volume settings)' 2>/dev/null)
            if [ "${LEVEL:-0}" -gt 0 ] 2>/dev/null; then
              printf '%s' "$LEVEL" > "$STATE"
              osascript -e 'set volume input volume 0' 2>/dev/null
            else
              PREV=$(cat "$STATE" 2>/dev/null | tr -dc '0-9')
              osascript -e "set volume input volume ${PREV:-75}" 2>/dev/null
            fi
            /opt/homebrew/bin/sketchybar --trigger panewright_widgets 2>/dev/null
            """
        let micURL = directory.appending(path: "mic-toggle.sh")
        try (micToggle + "\n").write(to: micURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: micURL.path)

        let moveURL = directory.appending(path: "move-window.sh")
        try (moveWindow + "\n").write(to: moveURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: moveURL.path)

        let script = """
            #!/bin/bash
            # Generated by Panewright — do not edit by hand.
            # i3 'scratchpad show': summon the first window stashed on the
            # hidden S workspace, floating, onto the focused workspace.
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
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
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
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

        let pillSummon = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            # $1 = 1-based pill number, as drawn on the bar. Delegates to the
            # toggle script so summon/park semantics stay in one place.
            PILLS="$HOME/.config/panewright/pills.tsv"
            N="$1"
            [ -z "$N" ] && exit 0
            ID=$(sed -n "${N}p" "$PILLS" 2>/dev/null | cut -f1)
            [ -z "$ID" ] && exit 0
            exec /bin/bash "$HOME/.config/panewright/scripts/pill-toggle.sh" "$ID"
            """

        let pillToggle = """
            #!/bin/bash
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            # Generated by Panewright — do not edit by hand.
            # $1 = window id. Parked -> summon it here; visible -> park it.
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
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
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
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
            A="$HOME/.config/panewright/bin/aerospace"; [ -x "$A" ] || A=/opt/homebrew/bin/aerospace
            MAP="$HOME/.config/panewright/monitor-map.tsv"
            MON=$(awk -F'\\t' -v d="$1" '$1 == d { print $2 }' "$MAP" 2>/dev/null)
            [ -z "$MON" ] && MON="$1"
            "$A" focus-monitor "$MON" 2>/dev/null
            "$A" workspace "$2" 2>/dev/null
            """

        // The rofi classics, shipped working: each is an ordinary script on
        // the `panewright menu` primitive, so they double as worked examples
        // for writing your own. All reachable from the $mod+D palette.
        let menuBin = "\"$HOME/.config/panewright/bin/panewright\" menu"
        let sshMenu = """
            #!/bin/bash
            # Generated by Panewright. Pick a host from ~/.ssh/config, connect
            # in your default terminal (ssh:// is handled by the system).
            HOST=$(grep -E "^Host " "$HOME/.ssh/config" 2>/dev/null \\
              | awk '{for (i=2; i<=NF; i++) print $i}' | grep -v '[*?]' \\
              | \(menuBin) "ssh to:") || exit 0
            exec open "ssh://$HOST"
            """
        let killMenu = """
            #!/bin/bash
            # Generated by Panewright. The classic process killer: heaviest
            # CPU first, pick one, it gets a polite TERM.
            LINE=$(ps -Arco pid=,pcpu=,comm= | head -25 \\
              | awk '{printf "%s  %s%%  %s\\n", $1, $2, $3}' \\
              | \(menuBin) "kill:") || exit 0
            exec kill "$(echo "$LINE" | awk '{print $1}')"
            """
        let powerMenu = """
            #!/bin/bash
            # Generated by Panewright. Sleep, lock, restart, and friends —
            # restart/shutdown/logout confirm through macOS itself.
            PICK=$(printf "Lock Screen\\nSleep\\nSleep Displays\\nRestart…\\nShut Down…\\nLog Out…" \\
              | \(menuBin) "power:") || exit 0
            case "$PICK" in
              "Lock Screen") open -b com.apple.ScreenSaver.Engine 2>/dev/null \\
                || pmset displaysleepnow ;;
              "Sleep") pmset sleepnow ;;
              "Sleep Displays") pmset displaysleepnow ;;
              "Restart…") osascript -e 'tell app "System Events" to restart' ;;
              "Shut Down…") osascript -e 'tell app "System Events" to shut down' ;;
              "Log Out…") osascript -e 'tell app "System Events" to log out' ;;
            esac
            """

        for (name, content) in [
            ("menu-ssh.sh", sshMenu), ("menu-kill.sh", killMenu),
            ("menu-power.sh", powerMenu),
            ("todo-add.sh", todoAdd), ("todo-edit.sh", todoEdit),
            ("pill-window.sh", pillWindow), ("pill-toggle.sh", pillToggle),
            ("pill-summon.sh", pillSummon),
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
    public func apply(dockInsetBottom: Int = 0, dockInsetSides: Int = 0) throws {
        refreshCLILink()
        let config = try loadConfig()
        try writeSupportScripts(config)
        try writeAerospaceConfig()
        if status() == .running, let cli = AeroSpaceCLI.locate() {
            try cli.run(["reload-config"])
        }
        try applyBorders(config)
        try applyBar(
            config, dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
    }

    /// Like borders: a missing binary is fine, bad config is not.
    /// The widget on/off list the bar driver reads at runtime. Kept as a flat
    /// file so flipping a widget is a write plus a trigger — no bar reload.
    public func writeEnabledWidgets(_ config: PanewrightConfig) throws {
        let file = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: ".widgets-enabled")
        let keys = PanewrightConfig.Modules.catalog
            .filter { config.modules[keyPath: $0.path] }
            .map(\.key)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (keys.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Bar item name for a widget key — the picker's order has to be
    /// translated into SketchyBar's item names to reorder without a reload.
    static let widgetItemNames: [String: String] = [
        "system-monitor": "sys", "system-graphs": "sys.cpu.graph", "network": "w.net", "ports": "w.ports", "disk": "w.disk",
        "battery": "w.batt", "docker": "w.docker", "cloud-context": "w.cloud",
        "scratchpad": "w.scratch", "mic-mute": "w.mic", "volume": "w.vol",
        "brew-updates": "w.brew", "vpn": "w.vpn", "keyboard-layout": "w.kbd",
        "focus-mode": "w.focus", "now-playing": "w.play", "weather": "w.weather",
    ]

    /// The widget item names in bar order (rightmost first, matching how
    /// SketchyBar stacks `right` items). Graphs stay adjacent to the chip they
    /// belong to, so the CPU/memory sparklines travel with their readout.
    public func writeWidgetOrder(_ config: PanewrightConfig) throws {
        let file = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: ".widgets-order")
        let items = config.modules.resolvedOrder.reversed().flatMap { key -> [String] in
            // Graphs have no chip of their own; they're emitted with the CPU
            // chip below, so ordering them separately would split the pair.
            guard key != "system-graphs", let name = Self.widgetItemNames[key] else { return [] }
            // Graphs ride with the chip so the pair never separates.
            return key == "system-monitor"
                ? (config.modules.systemGraphs
                    ? ["sys.cpu.graph", "sys.mem.graph", name] : [name])
                : [name]
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (items.joined(separator: "\n") + "\n").write(
            to: file, atomically: true, encoding: .utf8)
    }

    /// Flip widgets without rebuilding the bar: rewrite the runtime list,
    /// re-apply the order, and nudge the driver to repaint. Instant and
    /// flicker-free — a full reload visibly tears the bar down.
    public func refreshWidgets(_ config: PanewrightConfig) throws {
        try writeEnabledWidgets(config)
        guard let bar = SketchyBarSupervisor.locate(), bar.isRunning() else { return }
        // Hand the order to the reorder plugin rather than issuing our own
        // partial --reorder: a subset reorder shuffled widgets in between the
        // to-do pills and their "+" button. One authority, one call.
        try writeWidgetOrder(config)
        let reorder = Process()
        reorder.executableURL = URL(filePath: NSHomeDirectory())
            .appending(path: ".config/sketchybar/plugins/panewright_reorder.sh")
        reorder.standardOutput = FileHandle.nullDevice
        reorder.standardError = FileHandle.nullDevice
        try? reorder.run()
        reorder.waitUntilExit()
        let process = Process()
        process.executableURL = bar.executableURL
        process.arguments = ["--trigger", "panewright_widgets"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// The Dock moved or resized. Rewrite the bar config so the next restart
    /// agrees, and push the new side margin into the running bar directly —
    /// deliberately not `applyBar`, whose reload tears every item down and
    /// repopulates it, which is exactly the jank a Dock move shouldn't cause.
    ///
    /// Only the margin is pushed from here. The vertical offset is placed by
    /// the app layer (BarPlacer), which can measure the bar's real frame:
    /// SketchyBar's y_offset units are not points on every display, and this
    /// layer has no way to check what a push actually did.
    public func refreshBarGeometry(
        _ config: PanewrightConfig, dockInsetBottom: Int, dockInsetSides: Int
    ) throws {
        guard config.statusBar.enabled, let bar = SketchyBarSupervisor.locate() else { return }
        try writeSketchyBarConfig(
            config, dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
        guard bar.isRunning() else { return }
        let geometry = SketchyBarConfigEmitter.barGeometry(
            for: config.statusBar.theme,
            dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
        let process = Process()
        process.executableURL = bar.executableURL
        process.arguments = ["--bar", "margin=\(geometry.margin)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    public func applyBar(
        _ config: PanewrightConfig, dockInsetBottom: Int = 0, dockInsetSides: Int = 0
    ) throws {
        guard let bar = SketchyBarSupervisor.locate() else { return }
        if config.statusBar.enabled {
            try writeSketchyBarConfig(
                config, dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
            try writeEnabledWidgets(config)
            try writeWidgetOrder(config)
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

    func writeSketchyBarConfig(
        _ config: PanewrightConfig, dockInsetBottom: Int = 0, dockInsetSides: Int = 0
    ) throws {
        let files = try SketchyBarConfigEmitter.emit(
            config, dockInsetBottom: dockInsetBottom, dockInsetSides: dockInsetSides)
        let directory = paths.sketchybarConfigDirectory
        // A whole directory of someone else's scripts may live here, with
        // their plugins beside ours.
        ConfigBackup.preserveContents(of: directory, into: backupsDirectory)
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
            ("plugins/panewright_system.sh", files.systemPlugin),
            ("plugins/panewright_widgets.sh", files.widgetsPlugin),
            ("plugins/panewright_tooltip.sh", files.tooltipPlugin),
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

    /// Where configuration we replaced is kept, beside the config it belongs
    /// to rather than somewhere in Application Support nobody will find.
    public var backupsDirectory: URL {
        paths.panewrightConfigFile.deletingLastPathComponent().appending(path: "backups")
    }

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

    /// Validate a profile name the same way for every operation that takes
    /// one. A name with a slash escapes the profiles directory, and an empty
    /// one produces a file called ".toml" that lists as a profile with no name.
    private func profileURL(for name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw ConfigError.invalidProfileName(name)
        }
        return profilesDirectory.appending(path: "\(trimmed).toml")
    }

    public func deleteProfile(named name: String) throws {
        try FileManager.default.removeItem(at: try profileURL(for: name))
    }

    /// Rename in place. Refuses to overwrite an existing profile — silently
    /// replacing a saved config with a different one is not a rename.
    public func renameProfile(from oldName: String, to newName: String) throws {
        let source = try profileURL(for: oldName)
        let destination = try profileURL(for: newName)
        guard source != destination else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ConfigError.invalidProfileName("\(newName) already exists")
        }
        try FileManager.default.moveItem(at: source, to: destination)
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
        // When the engine ships inside the app bundle, spawn it as a direct
        // child rather than through Launch Services. The difference is who
        // macOS bills for its Accessibility use: a child process inherits the
        // parent's TCC responsibility, so the engine runs under *Panewright's*
        // grant and never appears in System Settings at all — one app, one
        // set of permissions. (`open` would launch it as its own responsible
        // process and put a second row back in the permissions table.)
        //
        // Named "AeroSpace" so the process name matches what teardown,
        // restart and the health checks already pkill/pgrep for.
        let embedded = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/AeroSpace")
        if FileManager.default.isExecutableFile(atPath: embedded.path) {
            // The engine's menu bar icon stays hidden — Panewright's bar owns
            // that surface. Written from code, every launch, because a manual
            // `defaults write` on the dev machine is an experience no fresh
            // install would share.
            UserDefaults(suiteName: "bobko.aerospace")?
                .set(true, forKey: "menu-bar-icon-hidden")
            let engine = Process()
            engine.executableURL = embedded
            // The engine's own words go to a file, not /dev/null. It died
            // silently across a screen sleep once — no crash report, no log,
            // nothing to diagnose with. Never again.
            let log = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/PanewrightEngine.log")
            LogTail.rotate(log.path)
            // Create, never truncate: the relaunch after a death would
            // otherwise wipe the termination line the death just wrote —
            // which is the one line the log exists to keep.
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: log)
            _ = try? handle?.seekToEnd()
            engine.standardOutput = handle ?? FileHandle.nullDevice
            engine.standardError = handle ?? FileHandle.nullDevice
            // Reap on exit and say how it went. Termination is pkill's job
            // (teardown), not ours — and an orphaned engine surviving a
            // Panewright crash keeps the user's windows managed, which is a
            // feature, not a leak.
            engine.terminationHandler = { process in
                let how =
                    process.terminationReason == .uncaughtSignal
                    ? "signal \(process.terminationStatus)"
                    : "exit \(process.terminationStatus)"
                let line = "\(Date().formatted(.iso8601)) engine terminated: \(how)\n"
                _ = try? handle?.write(contentsOf: Data(line.utf8))
                try? handle?.close()
            }
            try engine.run()
            return
        }
        try runTool("/usr/bin/open", ["-a", "AeroSpace"])
    }

    /// Accessibility grants only take effect at app launch, so "grant, then
    /// restart AeroSpace" is the canonical permission-onboarding step.
    public func restartAeroSpace() throws {
        try runTool("/usr/bin/pkill", ["-x", "AeroSpace"])
        Thread.sleep(forTimeInterval: 0.5)
        try launchAeroSpace()
    }

    /// Which window lives on which workspace, written continuously so an
    /// engine death doesn't erase the answer.
    ///
    /// The engine keeps workspace assignments in memory only: any restart —
    /// crash, kill, or the silent death one screen-sleep produced — dumps
    /// every window onto one workspace, and the user rebuilds their layout by
    /// hand. The snapshot is cheap (one CLI call), and restoring it turns an
    /// engine restart from "my environment reset" into a blip.
    public func snapshotWorkspaces() {
        guard let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-windows", "--all", "--format", "%{window-id}\t%{workspace}",
            ]),
            let focused = try? cli.run(["list-workspaces", "--focused"])
        else { return }
        // A snapshot of a broken engine would restore chaos; only write one
        // that names at least one real window on a real workspace.
        guard output.contains("\t") else { return }
        // Which workspace each monitor was showing, by monitor *name* — the
        // ids renumber across engine restarts, the names don't. Without this
        // an engine relaunch let AeroSpace pick fresh workspaces for the
        // secondary displays, so a sleep turned "3 on the portrait monitor"
        // into "4 on the portrait monitor" and the desk stopped matching the
        // muscle memory.
        let placements =
            ((try? cli.run([
                "list-workspaces", "--monitor", "all", "--visible",
                "--format", "%{monitor-name}\t%{workspace}",
            ])) ?? "")
            .split(separator: "\n")
            .map { "MONITOR\t\($0)" }
            .joined(separator: "\n")
        let file = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: ".workspace-snapshot")
        try? (output + "\nFOCUSED\t" + focused.trimmingCharacters(in: .whitespacesAndNewlines)
            + (placements.isEmpty ? "" : "\n" + placements))
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Put every window the snapshot knows back on its workspace. Windows
    /// that closed in the meantime are skipped by the engine itself (the move
    /// fails, harmlessly); new windows stay where they landed.
    ///
    /// Returns how many windows actually moved — callers must not report a
    /// restore that didn't happen. The unconditional "restored" log once
    /// fired one second after an engine launch while every window sat
    /// un-adopted on workspace 0.
    @discardableResult
    public func restoreWorkspaces() -> Int {
        guard let cli = AeroSpaceCLI.locate() else { return 0 }
        let file = paths.panewrightConfigFile.deletingLastPathComponent()
            .appending(path: ".workspace-snapshot")
        // A snapshot goes stale: it refreshes every 20s while the app runs
        // and at teardown, so anything older means the app has been gone a
        // while — and restoring an old layout over one the user has since
        // rearranged is worse than restoring nothing. (Window ids also die
        // with app relaunches, so ancient snapshots mostly no-op — mostly.)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
            let modified = attrs[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) > 600
        {
            return 0
        }
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        // A freshly launched engine answers its socket before it has adopted
        // the existing windows; moves issued in that gap no-op and the
        // "restore" scatters nothing back. Wait until the engine can see at
        // least one window the snapshot names (or give up after ~6s).
        let snapshotIDs = Set(
            content.split(separator: "\n").compactMap {
                $0.split(separator: "\t").first.map(String.init)
            }.filter { $0 != "FOCUSED" })
        for _ in 0..<12 {
            if let listing = try? cli.run(["list-windows", "--all", "--format", "%{window-id}"]),
                listing.split(separator: "\n").contains(where: {
                    snapshotIDs.contains($0.trimmingCharacters(in: .whitespaces))
                })
            {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        var focused: String?
        var placements: [(monitorName: String, workspace: String)] = []
        var moved = 0
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "FOCUSED" {
                focused = parts[1]
            } else if parts[0] == "MONITOR" {
                let sub = parts[1].split(separator: "\t", maxSplits: 1).map(String.init)
                if sub.count == 2 { placements.append((sub[0], sub[1])) }
            } else if (try? cli.run([
                "move-node-to-workspace", "--window-id", parts[0], parts[1],
            ])) != nil {
                moved += 1
            }
        }
        // Put each monitor's workspace back where it was, matched by name —
        // idempotent when nothing changed, and a monitor that's gone simply
        // doesn't match. Focusing the workspace is what makes it the visible
        // one on its monitor; the user's focus is put back last.
        if !placements.isEmpty, let monitorsOut = try? cli.run(["list-monitors"]) {
            var idByName: [String: String] = [:]
            for line in monitorsOut.split(separator: "\n") {
                let parts = line.components(separatedBy: " | ")
                guard parts.count == 2 else { continue }
                idByName[parts[1].trimmingCharacters(in: .whitespaces).lowercased()] =
                    parts[0].trimmingCharacters(in: .whitespaces)
            }
            for placement in placements {
                guard let id = idByName[placement.monitorName.lowercased()] else { continue }
                try? cli.run([
                    "move-workspace-to-monitor", "--workspace", placement.workspace, id,
                ])
                try? cli.run(["workspace", placement.workspace])
            }
        }
        if let focused, !focused.isEmpty, moved > 0 || !placements.isEmpty {
            try? cli.run(["workspace", focused])
        }
        return moved
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

    public func isAeroSpaceProcessRunning() -> Bool {
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
