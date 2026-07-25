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
        // The native menu bar owns the clock and wifi; our bar never adds them.
        // (Battery is different: it's an opt-in widget, and it shows the time
        // remaining that the menu bar icon hides.)
        let files = try SketchyBarConfigEmitter.emit(.default)
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

    @Test func systemMonitorModuleIsOptIn() throws {
        // Off by default: no chip, no graphs, an empty plugin.
        let off = try SketchyBarConfigEmitter.emit(.default)
        #expect(!off.sketchybarrc.contains("--add item sys "))
        #expect(!off.sketchybarrc.contains("sys.cpu.graph"))

        var config = PanewrightConfig.default
        config.modules.systemMonitor = true
        let on = try SketchyBarConfigEmitter.emit(config)
        // Chip, two sparkline graphs, and the perf-panel popup rows.
        #expect(on.sketchybarrc.contains("--add graph sys.cpu.graph"))
        #expect(on.sketchybarrc.contains("--add graph sys.mem.graph"))
        #expect(on.sketchybarrc.contains("popup.drawing=toggle"))
        #expect(on.sketchybarrc.contains("sys.pop.cpu.5 popup.sys"))
        // The plugin pushes graph values and only fills the panel when open.
        #expect(on.systemPlugin.contains("--push sys.cpu.graph"))
        #expect(on.systemPlugin.contains(#"[ "$OPEN" != "on" ] && exit 0"#))
        #expect(on.systemPlugin.contains("vm_stat"))
    }

    @Test func widgetsToggleAtRuntimeWithoutRebuildingTheBar() throws {
        var config = PanewrightConfig.default
        config.modules.network = true
        config.modules.ports = true
        let files = try SketchyBarConfigEmitter.emit(config)
        // Items exist regardless of what's enabled, so flipping a widget is a
        // repaint rather than a bar reload (which visibly tore the bar down).
        #expect(files.sketchybarrc.contains("--add item w.net"))
        #expect(files.sketchybarrc.contains("--add item w.docker"))
        // Enabled state is read at runtime from the generated list.
        #expect(files.widgetsPlugin.contains(#"on() { grep -qx "$1" "$ENABLED" 2>/dev/null; }"#))
        #expect(files.widgetsPlugin.contains("if on network; then"))
        #expect(files.widgetsPlugin.contains("if on docker; then"))
        // A disabled widget is actively hidden, so stale labels can't linger.
        #expect(files.widgetsPlugin.contains("--set w.docker drawing=off"))
        // ONE driver refreshes them all, and a trigger repaints on demand.
        #expect(files.sketchybarrc.contains("--subscribe widgets_driver panewright_widgets"))
        #expect(files.sketchybarrc.components(separatedBy: "panewright_widgets.sh").count == 2)
        #expect(files.widgetsPlugin.contains(#""$BAR" "${ARGS[@]}""#))
    }

    @Test func widgetsNameThemselvesOnHoverHold() throws {
        var config = PanewrightConfig.default
        config.modules.network = true
        config.modules.ports = true
        let files = try SketchyBarConfigEmitter.emit(config)
        // Each widget subscribes to hover and carries a name row in its popup.
        #expect(files.sketchybarrc.contains("--subscribe w.net mouse.entered mouse.exited"))
        #expect(files.sketchybarrc.contains(#"--set w.net.tip label="Network"#))
        // Ports already has a detail popup, so its title row doubles as the tip.
        #expect(files.sketchybarrc.contains(#"--set w.ports.tip label="Listening ports""#))
        // The reveal is delayed and cancelable, so sweeping past never flashes.
        #expect(files.tooltipPlugin.contains("HOLD=3"))
        #expect(files.tooltipPlugin.contains("mouse.exited"))
        #expect(files.tooltipPlugin.contains(#"[ "$(cat "$STATE" 2>/dev/null)" = "$TOKEN" ]"#))
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

@Suite struct WidgetOrderingTests {
    @Test func orderSurvivesAlongsideToggles() throws {
        // A non-boolean key in [modules] must not wipe out the toggles.
        let config = try ConfigParser.parse(
            toml: """
                [modules]
                weather = true
                battery = true
                order = ["weather", "battery"]
                """)
        #expect(config.modules.weather)
        #expect(config.modules.battery)
        #expect(config.modules.order == ["weather", "battery"])
        // Configured keys lead; everything else follows in catalog order, so a
        // newly added widget still appears without editing the order.
        let resolved = config.modules.resolvedOrder
        #expect(resolved.prefix(2) == ["weather", "battery"])
        #expect(Set(resolved) == Set(PanewrightConfig.Modules.catalog.map(\.key)))
        // Round-trips.
        #expect(try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config)).modules
            == config.modules)
    }
}

@Suite struct BindingConflictTests {
    @Test func flagsDuplicateKeysAndSystemChords() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),
            .init(key: "1", action: .workspace(9)),   // duplicate
            .init(key: "space", action: .fullscreen), // ctrl-cmd-space = Emoji picker
            .init(key: "j", action: .focus(.down)),
        ]
        let conflicts = BindingConflicts.find(in: config)
        #expect(conflicts.count == 2)
        // The duplicate names both actions, so it's obvious which one wins.
        let duplicate = conflicts.first { $0.key == "1" }
        #expect(duplicate?.summary.contains("bound twice") == true)
        #expect(duplicate?.summary.contains("workspace 9") == true)
        // The system chord names its owner rather than just saying "conflict".
        #expect(conflicts.first { $0.key == "space" }?.summary.contains("Emoji") == true)
        // A clean binding isn't flagged.
        #expect(!conflicts.contains { $0.key == "j" })
    }

    @Test func modeKeysAreScopedAndNeverSystemChords() {
        var config = PanewrightConfig.default
        config.bindings = []
        config.modes = [
            .init(name: "resize", bindings: [
                .init(key: "h", action: .resize(.width, -50)),
                .init(key: "h", action: .resize(.width, 50)),
            ])
        ]
        let conflicts = BindingConflicts.find(in: config)
        // Same key in different modes is fine; the same key twice in one is not.
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.scope == "resize")
        // Mode keys are bare, so they can't collide with a macOS chord.
        #expect(conflicts.allSatisfy { if case .duplicate = $0.kind { true } else { false } })
    }

    @Test func defaultsHaveOneKnownSystemCollision() {
        // Found by this detector on its first run: the default $mod+f
        // (fullscreen) becomes ctrl-cmd-f, which is macOS's own "Enter Full
        // Screen". Apps with that menu item swallow it before AeroSpace sees
        // it. Asserted rather than hidden so the decision to rebind is
        // deliberate — and so a NEW conflict still fails this test.
        let conflicts = BindingConflicts.find(in: .default)
        let system = conflicts.filter { if case .systemShortcut = $0.kind { true } else { false } }
        #expect(system.count == 1)
        #expect(system.first?.key == "f")
        #expect(system.first?.summary.contains("Enter Full Screen") == true)

        // And the ergonomics check measures the other half of the problem:
        // under the ctrl-cmd default, every $mod+Shift binding is a
        // three-modifier stretch. That count is the case for replacing them
        // with a mode — it should go DOWN, never up.
        let awkward = conflicts.filter { if case .awkward = $0.kind { true } else { false } }
        #expect(awkward.count == 20)
    }
}

@Suite struct BindingConflictModifierTests {
    @Test func theSameKeyConflictsOnlyUnderSomeModifiers() {
        // $mod+f is fine or broken depending entirely on the modifier: ctrl-cmd-f
        // is macOS's Enter Full Screen, alt-f is nobody's. Conflicts must be
        // judged on the resolved chord, never the bare key.
        var clashing = PanewrightConfig.default
        clashing.modifier = .ctrlCmd
        clashing.bindings = [.init(key: "f", action: .fullscreen)]
        #expect(BindingConflicts.find(in: clashing).count == 1)

        var fine = clashing
        fine.modifier = .alt
        #expect(BindingConflicts.find(in: fine).isEmpty)

        var hyper = clashing
        hyper.modifier = .hyper
        #expect(BindingConflicts.find(in: hyper).isEmpty)
    }
}

@Suite struct ErgonomicsWarningTests {
    @Test func flagsThreeModifierChordsAndNamesTheFix() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),          // ⌃⌘1 — fine
            .init(key: "shift-1", action: .moveToWorkspace(1)),  // ⌃⌘⇧1 — a stretch
        ]
        let awkward = BindingConflicts.awkwardChords(in: config)
        #expect(awkward.count == 1)
        #expect(awkward.first?.key == "shift-1")
        #expect(awkward.first?.summary.contains("3 modifiers") == true)
        // The warning has to name the remedy, not just the problem.
        #expect(awkward.first?.summary.contains("mode") == true)
    }

    @Test func oneKeyAndSingleModifierSetupsAreNeverAwkward() {
        var config = PanewrightConfig.default
        config.bindings = [.init(key: "shift-1", action: .moveToWorkspace(1))]
        // Caps Lock hyper is one physical key, so ⇧ on top is still two fingers.
        config.modifier = .hyper
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
        // A single modifier plus shift is two keys — also fine.
        config.modifier = .alt
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
        // Leader style holds nothing at all.
        config.modifier = .leader
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
    }
}
