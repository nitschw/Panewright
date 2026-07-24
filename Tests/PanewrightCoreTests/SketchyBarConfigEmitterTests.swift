import Testing

@testable import PanewrightCore

@Suite struct SketchyBarConfigEmitterTests {
    @Test func nativeThemeEmitsBarAndWorkspaceItems() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("position=bottom"))
        #expect(files.sketchybarrc.contains("corner_radius=9"))
        #expect(files.sketchybarrc.contains("SF Pro"))
        #expect(files.sketchybarrc.contains("for sid in 1 2 3 4 5 6 7 8 9 0"))
        // Per-display strips filtered to each monitor's own workspaces.
        #expect(files.sketchybarrc.contains("associated_display=$did"))
        #expect(files.sketchybarrc.contains("workspace-select.sh $did $sid"))
        #expect(files.workspacesPlugin.contains("list-workspaces --monitor"))
        // i3-style dynamic pills: only occupied or visible workspaces draw.
        #expect(files.workspacesPlugin.contains("--empty no"))
        #expect(files.workspacesPlugin.contains("drawing=off"))
        #expect(files.sketchybarrc.contains("--add event panewright_mode"))
        // Initial highlight retries until AeroSpace answers (any launch order).
        #expect(files.sketchybarrc.contains("for attempt in $(seq 1 20)"))
    }

    @Test func technicalThemeIsSquareAndMonospace() throws {
        var config = PanewrightConfig.default
        config.statusBar.theme = .technical
        let files = try SketchyBarConfigEmitter.emit(config)
        #expect(files.sketchybarrc.contains("corner_radius=0"))
        #expect(files.sketchybarrc.contains("SF Mono"))
    }

    @Test func accentColorFollowsFocusBorder() throws {
        var config = PanewrightConfig.default
        config.focusBorder.activeColor = "#FF375F"
        let files = try SketchyBarConfigEmitter.emit(config)
        #expect(files.workspacesPlugin.contains("0xffff375f"))
    }

    @Test func barAccentCanBreakAwayFromTheBorder() throws {
        var config = PanewrightConfig.default
        config.focusBorder.activeColor = "#FF375F"
        config.statusBar.accentColor = "#30D158"
        let files = try SketchyBarConfigEmitter.emit(config)
        // The pill highlight uses the bar accent, not the border color.
        #expect(files.workspacesPlugin.contains("0xff30d158"))
        #expect(!files.workspacesPlugin.contains("0xffff375f"))
        // Round-trips through the config file.
        let toml = PanewrightConfigSerializer.emit(config)
        #expect(toml.contains("accent-color = \"#30D158\""))
        #expect(try ConfigParser.parse(toml: toml).statusBar.accentColor == "#30D158")
    }

    @Test func workspaceStripsRepaintFromOneBatchedDriver() throws {
        // One driver process per event, not one per pill — a per-pill stampede
        // (30 forks, 60 AeroSpace queries) has crashed SketchyBar.
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("--subscribe spaces_driver aerospace_workspace_change"))
        #expect(!files.sketchybarrc.contains("--subscribe space.$did.$sid"))
        #expect(files.workspacesPlugin.contains("ARGS+=("))
    }

    @Test func eachStripLeadsWithItsMonitorBadge() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("--add item monitor.$did left"))
        // Badge shows the human-facing number (map col 3, primary = M1),
        // falling back to the AeroSpace id for an old-format map.
        #expect(files.workspacesPlugin.contains(#"label="M${LBL:-$MON}""#))
        // The badge slots in ahead of its display's workspace pills.
        #expect(files.sketchybarrc.contains("monitor.1 space.1."))
    }

    @Test func omitsSystemStatusItems() throws {
        // The native menu bar owns clock/wifi/battery; our bar is pure WM.
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(!files.sketchybarrc.contains("battery"))
        #expect(!files.sketchybarrc.contains("wifi"))
        #expect(!files.sketchybarrc.contains("clock"))
        #expect(files.sketchybarrc.contains("front_app"))
    }

    @Test func pluginsDoNotDependOnInheritedPATH() throws {
        // GUI-launched daemons inherit a minimal PATH, so a bare `sketchybar`
        // in a plugin silently fails — every plugin must set PATH itself.
        let files = try SketchyBarConfigEmitter.emit(.default)
        for plugin in [files.workspacesPlugin, files.modePlugin, files.frontAppPlugin] {
            #expect(plugin.contains("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\""))
            #expect(!plugin.contains("\nsketchybar "))
        }
    }

    @Test func todoItemAndPopupAreEmittedWhenEnabled() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("--add event panewright_todo"))
        #expect(files.sketchybarrc.contains("todo-add.sh"))
        // One pill per task, growing from the right.
        #expect(files.todoPlugin.contains("--add item todo.item.$i right"))
        #expect(files.todoPlugin.contains("todo-edit.sh"))
        #expect(files.todoPlugin.contains("todo.txt"))
    }

    @Test func todoDisappearsWhenDisabled() throws {
        var config = PanewrightConfig.default
        config.todo.enabled = false
        let files = try SketchyBarConfigEmitter.emit(config)
        #expect(!files.sketchybarrc.contains("--add item todo"))
        #expect(!files.sketchybarrc.contains("--trigger panewright_todo"))
    }

    @Test func windowPillsRenderAndPrune() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("--add event panewright_pills"))
        #expect(files.pillsPlugin.contains("pill-toggle.sh"))
        #expect(files.pillsPlugin.contains("pill-release.sh"))
        // Parked windows live on the hidden P workspace.
        #expect(files.pillsPlugin.contains("--workspace P"))
        // Closed windows shouldn't leave orphaned pills behind.
        #expect(files.pillsPlugin.contains("grep -qx \"$id\" || continue"))
    }

    @Test func modePluginUppercasesAndClears() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.modePlugin.contains(#"[ "$MODE" = "main" ]"#))
        #expect(files.modePlugin.contains("tr '[:lower:]' '[:upper:]'"))
    }
}

@Suite struct BarConfigParsingTests {
    @Test func parsesBarSection() throws {
        let config = try ConfigParser.parse(
            toml: """
                [bar]
                enabled = false
                theme = "technical"
                """)
        #expect(config.statusBar.enabled == false)
        #expect(config.statusBar.theme == .technical)
    }

    @Test func parsesHooksAndBackAndForth() throws {
        #expect(
            try ConfigParser.parseAction("workspace back_and_forth") == .workspaceBackAndForth)
        let config = try ConfigParser.parse(
            toml: """
                [hooks]
                workspace-changed = "python3 ~/hooks/ws.py"
                """)
        #expect(config.workspaceChangedHook == "python3 ~/hooks/ws.py")
        let toml = PanewrightConfigSerializer.emit(config)
        #expect(try ConfigParser.parse(toml: toml) == config)
        let aerospace = AeroSpaceConfigEmitter.emit(config)
        #expect(aerospace.contains("on-workspace-change.sh"))
        #expect(aerospace.contains("ctrl-cmd-tab = 'workspace-back-and-forth'"))
    }

    @Test func focusChangedHookRoundTripsAndEmitsCallback() throws {
        let config = try ConfigParser.parse(
            toml: """
                [hooks]
                focus-changed = "logger -t pw $FOCUSED_APP"
                """)
        #expect(config.focusChangedHook == "logger -t pw $FOCUSED_APP")
        // Round-trips through the serializer.
        #expect(try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config)) == config)
        // Emits the on-focus-changed callback — but never a bar repaint there.
        let aerospace = AeroSpaceConfigEmitter.emit(config)
        #expect(aerospace.contains("on-focus-changed = ['exec-and-forget /bin/bash"))
        #expect(aerospace.contains("on-focus-change.sh"))
        #expect(!aerospace.contains("on-focus-changed = ['exec-and-forget /opt/homebrew/bin/sketchybar"))
        // No hook set → no callback emitted.
        #expect(!AeroSpaceConfigEmitter.emit(.default).contains("on-focus-changed"))
    }

    @Test func helpActionRoundTripsAndOpensTheCheatSheet() throws {
        #expect(try ConfigParser.parseAction("help") == .help)
        let toml = AeroSpaceConfigEmitter.emit(.default)
        // $mod+? — shift-slash — opens the cheat sheet via the URL scheme.
        #expect(toml.contains("shift-slash"))
        #expect(toml.contains("exec-and-forget open panewright://help"))
        let serialized = PanewrightConfigSerializer.emit(.default)
        #expect(try ConfigParser.parse(toml: serialized) == PanewrightConfig.default)
    }

    @Test func parsesScratchpadAndWorkspaceApps() throws {
        #expect(try ConfigParser.parseAction("scratchpad show") == .scratchpadShow)
        #expect(try ConfigParser.parseAction("move scratchpad") == .scratchpadMove)
        let config = try ConfigParser.parse(
            toml: """
                [workspace-apps]
                "com.apple.Music" = 3
                """)
        #expect(config.appWorkspaces == ["com.apple.Music": 3])
    }

    @Test func serializerOmitsDefaultBindings() throws {
        let toml = PanewrightConfigSerializer.emit(.default)
        #expect(!toml.contains("[[binding]]"))
        #expect(!toml.contains("[[mode]]"))
        var custom = PanewrightConfig.default
        custom.bindings.append(.init(key: "t", action: .workspace(4)))
        #expect(PanewrightConfigSerializer.emit(custom).contains("[[binding]]"))
    }

    @Test func normalizesHumanFriendlyLeaderKeys() throws {
        // `+` separators and punctuation glyphs must become AeroSpace syntax,
        // or an invalid binding silently breaks every keybinding.
        #expect(ConfigParser.normalizeKeySpec("cmd+`") == "cmd-backtick")
        #expect(ConfigParser.normalizeKeySpec("cmd+~") == "cmd-shift-backtick")
        #expect(ConfigParser.normalizeKeySpec("ctrl-cmd-space") == "ctrl-cmd-space")
        #expect(ConfigParser.normalizeKeySpec("cmd-minus") == "cmd-minus")
        // An explicit shift plus a shifted glyph shouldn't double up.
        #expect(ConfigParser.normalizeKeySpec("cmd+shift+~") == "cmd-shift-backtick")
        // And it actually lands on the config through the parser.
        let config = try ConfigParser.parse(
            toml: """
                modifier = "leader"
                leader-key = "cmd+`"
                """)
        #expect(config.leaderKey == "cmd-backtick")
    }

    @Test func rejectsUnknownTheme() {
        let toml = """
            [bar]
            theme = "cyberpunk"
            """
        #expect(throws: ConfigError.invalidTheme("cyberpunk")) {
            try ConfigParser.parse(toml: toml)
        }
    }
}
