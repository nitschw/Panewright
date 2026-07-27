import Testing

@testable import PanewrightCore

@Suite struct SketchyBarConfigEmitterTests {
    @Test func nativeThemeEmitsBarAndWorkspaceItems() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("position=bottom"))
        #expect(files.sketchybarrc.contains("corner_radius=9"))
        #expect(files.sketchybarrc.contains("SF Pro"))
        // Numeric order, not number-row order: the bar reads as a list of
        // numbers, and 0 trailing 9 there looks like a bug.
        #expect(files.sketchybarrc.contains("for sid in 0 1 2 3 4 5 6 7 8 9"))
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

    @Test func systemMonitorModuleCanBeTurnedOff() throws {
        // Widgets default ON (2026-07-27, matching the dogfooded setup) —
        // turning one off must remove its items entirely.
        var offConfig = PanewrightConfig.default
        offConfig.modules.systemMonitor = false
        offConfig.modules.systemGraphs = false
        let off = try SketchyBarConfigEmitter.emit(offConfig)
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
        #expect(aerospace.contains("alt-tab = 'workspace-back-and-forth'"))
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
        #expect(ConfigParser.normalizeKeySpec("alt-space") == "alt-space")
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


/// The count on its own is a nag. Clicking it used to open an empty Terminal
/// and leave you to remember the command.
@Suite struct BrewWidgetTests {
    private func rcWithBrew() throws -> String {
        var config = PanewrightConfig.default
        config.modules.brewUpdates = true
        return try SketchyBarConfigEmitter.emit(config).sketchybarrc
    }

    @Test func clickingUnfurlsTheListInsteadOfOpeningATerminal() throws {
        let rc = try rcWithBrew()
        #expect(rc.contains("--add item w.brew right"))
        #expect(rc.contains("w.brew popup.drawing=toggle"))
        // The old behaviour, which told you nothing.
        #expect(!rc.contains("w.brew") || !rc.contains("label=\"⬆\" click_script=\"open -a Terminal\""))
    }

    @Test func thePopupHasRowsForPackagesAndAnUpgradeAction() throws {
        let rc = try rcWithBrew()
        #expect(rc.contains("w.brew.1 popup.w.brew"))
        #expect(rc.contains("w.brew.10 popup.w.brew"))
        // A long list is truncated with a count rather than running off screen.
        #expect(rc.contains("w.brew.more popup.w.brew"))
        #expect(rc.contains("Upgrade All"))
        // Visible Terminal: brew asks questions, and an upgrade hanging
        // invisibly on a prompt is worse than one you can see.
        #expect(rc.contains("brew upgrade"))
    }

    @Test func theCountComesFromTheSameListThePopupShows() throws {
        let plugin = try SketchyBarConfigEmitter.emit({
            var c = PanewrightConfig.default
            c.modules.brewUpdates = true
            return c
        }()).widgetsPlugin
        // Counting lines of the cache means the chip and the list it opens
        // can't disagree — they're the same data.
        #expect(plugin.contains("grep -c . \"$BREWC\""))
    }
}

@Suite struct BrewUpgradeRefreshTests {
    private func upgradeLine() throws -> String {
        var config = PanewrightConfig.default
        config.modules.brewUpdates = true
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        return String(
            rc.split(separator: "\n")
                .first { $0.contains("--add item w.brew.upgrade") } ?? "")
    }

    /// Upgrading has to rewrite the cache itself. The app's sweep is hourly, so
    /// upgrading just after one left the chip insisting twenty packages were
    /// out of date for the rest of the hour — indistinguishable, from the bar,
    /// from the indicator being broken.
    @Test func upgradingRewritesTheCacheItself() throws {
        let line = try upgradeLine()
        #expect(line.contains("brew upgrade;"))
        #expect(line.contains("brew outdated --quiet"))
    }

    /// Straight to the real file would leave it empty if the run is interrupted
    /// — which the widget reads as "nothing outdated", the most misleading
    /// answer available.
    @Test func theCacheIsWrittenViaATempFile() throws {
        let line = try upgradeLine()
        #expect(line.contains(".brew-outdated.new"))
        #expect(line.contains("&& mv"))
    }
}

/// Keeping the bar clear of a Dock along the bottom edge.
///
/// SketchyBar pins the bar to the bottom of the raw screen and has no idea the
/// Dock exists, so a bottom Dock — the macOS default — sits on top of it. Only
/// that one placement shares an edge with the bar; left, right and top Docks
/// need no adjustment, and asking for one would push the bar off its edge for
/// no reason.
@Suite struct DockClearanceTests {
    private func barLine(dockInsetBottom: Int, theme: PanewrightConfig.StatusBar.Theme)
        throws -> String
    {
        var config = PanewrightConfig.default
        config.statusBar.theme = theme
        let rc = try SketchyBarConfigEmitter.emit(config, dockInsetBottom: dockInsetBottom)
            .sketchybarrc
        return String(
            rc.split(separator: "\n").first { $0.contains("$BAR --bar ") } ?? "")
    }

    @Test func noDockOnTheBottomLeavesTheBarWhereItWas() throws {
        #expect(try barLine(dockInsetBottom: 0, theme: .native).contains("y_offset=5"))
        #expect(try barLine(dockInsetBottom: 0, theme: .technical).contains("y_offset=0"))
    }

    @Test func aBottomDockLiftsTheBarClearOfIt() throws {
        // A 64pt Dock: the bar's own 5pt offset plus the Dock's height.
        #expect(try barLine(dockInsetBottom: 64, theme: .native).contains("y_offset=69"))
        #expect(try barLine(dockInsetBottom: 64, theme: .technical).contains("y_offset=64"))
    }

    /// The bar keeps its height and position; only the offset moves. A lift
    /// that also changed the height would eat the space it just reserved.
    @Test func onlyTheOffsetChanges() throws {
        let lifted = try barLine(dockInsetBottom: 64, theme: .native)
        #expect(lifted.contains("position=bottom"))
        #expect(lifted.contains("height=30"))
    }
}

/// A Dock on the left or right overlaps the *end* of the bar, not its face.
///
/// margin is SketchyBar's only horizontal lever and insets both ends equally,
/// so clearing a 50pt left Dock costs 50pt on the right too. There is no
/// margin_left. A slightly narrower centred bar beats one that disappears
/// under the Dock at one end.
@Suite struct SideDockClearanceTests {
    private func barLine(sides: Int, theme: PanewrightConfig.StatusBar.Theme) throws -> String {
        var config = PanewrightConfig.default
        config.statusBar.theme = theme
        let rc = try SketchyBarConfigEmitter.emit(config, dockInsetSides: sides).sketchybarrc
        return String(
            rc.split(separator: "\n").first { $0.contains("$BAR --bar ") } ?? "")
    }

    @Test func noSideDockLeavesTheThemeMarginAlone() throws {
        #expect(try barLine(sides: 0, theme: .native).contains("margin=8"))
        #expect(try barLine(sides: 0, theme: .technical).contains("margin=0"))
    }

    @Test func aSideDockWidensTheMarginToClearIt() throws {
        #expect(try barLine(sides: 50, theme: .native).contains("margin=50"))
        #expect(try barLine(sides: 50, theme: .technical).contains("margin=50"))
    }

    /// A Dock thinner than the margin the theme already has changes nothing —
    /// the bar was already clear of it.
    @Test func aThinDockDoesNotShrinkAnExistingMargin() throws {
        #expect(try barLine(sides: 4, theme: .native).contains("margin=8"))
    }
}

/// The right-side order authority must be serialized and self-healing.
///
/// Every item-adding plugin triggers a reorder when its count changes, and at
/// startup they all fire at once. Unserialized, two reorders raced: the one
/// that started earliest — having never seen its peers' items — could apply
/// last, stranding whichever group it missed. The bar came up in a different
/// order every launch.
@Suite struct ReorderSerializationTests {
    private func files() throws -> SketchyBarConfigEmitter.Files {
        var config = PanewrightConfig.default
        config.modules.brewUpdates = true
        return try SketchyBarConfigEmitter.emit(config)
    }

    @Test func reorderRunsUnderALatestWinsLock() throws {
        let plugin = try files().reorderPlugin
        #expect(plugin.contains("mkdir \"$LOCK\""))
        // A request during a run loops the runner rather than being dropped —
        // the final pass has to see the complete bar.
        #expect(plugin.contains("$LOCK/again"))
        #expect(plugin.contains("trap 'rm -rf \"$LOCK\"' EXIT"))
    }

    @Test func widgetsDriverHealsOrderDrift() throws {
        let widgets = try files().widgetsPlugin
        #expect(widgets.contains(".widgets-order"))
        #expect(widgets.contains("panewright_reorder.sh"))
    }
}

/// The bar knobs that were baked into the themes, now configurable.
@Suite struct BarSettingsTests {
    private func barLine(_ mutate: (inout PanewrightConfig) -> Void) throws -> String {
        var config = PanewrightConfig.default
        mutate(&config)
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        return String(rc.split(separator: "\n").first { $0.contains("$BAR --bar ") } ?? "")
    }

    @Test func defaultsMatchWhatTheThemesAlwaysShipped() throws {
        let line = try barLine { _ in }
        #expect(line.contains("position=bottom"))
        #expect(line.contains("height=30"))
        #expect(line.contains("color=0x2c000000"))
        #expect(line.contains("show_in_fullscreen=off"))
    }

    @Test func everyKnobReachesTheBar() throws {
        let line = try barLine {
            $0.statusBar.position = .top
            $0.statusBar.thickness = 40
            $0.statusBar.fontSize = 16
            $0.statusBar.showInFullscreen = true
            $0.statusBar.opacity = 1.0
        }
        #expect(line.contains("position=top"))
        #expect(line.contains("height=40"))
        #expect(line.contains("show_in_fullscreen=on"))
        // Full opacity, theme's base color.
        #expect(line.contains("color=0xff000000"))
    }

    /// A top bar moves the tiles' reserved strip with it, and a thicker bar
    /// reserves more — the reserve derives from the thickness, so the two
    /// cannot disagree.
    @Test func theReservedStripFollowsTheBar() {
        var config = PanewrightConfig.default
        config.gaps = .init(inner: 8, outer: 8)
        config.statusBar.position = .top
        config.statusBar.thickness = 50
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("outer.top = 68"))  // 8 + 50 + 10
        #expect(toml.contains("outer.bottom = 8"))
    }

    @Test func theKnobsRoundTripThroughTheConfigFile() throws {
        var config = PanewrightConfig.default
        config.statusBar.position = .top
        config.statusBar.thickness = 34
        config.statusBar.fontSize = 15
        config.statusBar.showInFullscreen = true
        config.statusBar.opacity = 0.5
        let parsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(parsed.statusBar.position == .top)
        #expect(parsed.statusBar.thickness == 34)
        #expect(parsed.statusBar.fontSize == 15)
        #expect(parsed.statusBar.showInFullscreen == true)
        #expect(parsed.statusBar.opacity == 0.5)
    }

    @Test func verticalPositionsAreRefusedLoudly() {
        // SketchyBar coerces left/right to top silently; we refuse instead.
        #expect(throws: ConfigError.invalidBarPosition("left")) {
            _ = try ConfigParser.parse(toml: "[bar]\nposition = \"left\"")
        }
    }
}

/// The auto-hiding bar: hidden at start, strip reclaimed, config round-trips.
@Suite struct AutoHideTests {
    @Test func autoHideStartsHiddenAndReclaimsTheStrip() throws {
        var config = PanewrightConfig.default
        config.statusBar.autoHide = true
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        #expect(rc.contains("y_offset=\(SketchyBarConfigEmitter.hiddenOffset(for: config.statusBar))"))
        #expect(SketchyBarConfigEmitter.reservedGap(for: config.statusBar) == 0)
        // And the engine's gaps agree — no reserved strip.
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.bottom = 10"))
    }

    @Test func offByDefaultAndRoundTrips() throws {
        let rc = try SketchyBarConfigEmitter.emit(.default).sketchybarrc
        let barLine = rc.split(separator: "\n").first { $0.contains("$BAR --bar ") } ?? ""
        #expect(!barLine.contains("y_offset=-"))
        var config = PanewrightConfig.default
        config.statusBar.autoHide = true
        config.statusBar.autoHideDelay = 12
        let parsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(parsed.statusBar.autoHide)
        #expect(parsed.statusBar.autoHideDelay == 12)
    }
}
