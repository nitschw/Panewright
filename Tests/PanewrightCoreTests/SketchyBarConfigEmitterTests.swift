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
