import Testing

@testable import PanewrightCore

@Suite struct AeroSpaceConfigEmitterTests {
    @Test func emitsGaps() {
        var config = PanewrightConfig.default
        config.gaps = .init(inner: 10, outer: 6)
        config.statusBar.enabled = false
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("inner.horizontal = 10"))
        #expect(toml.contains("inner.vertical = 10"))
        #expect(toml.contains("outer.top = 6"))
        #expect(toml.contains("outer.left = 6"))
    }

    @Test func statusBarReservesTheBottomEdge() {
        var config = PanewrightConfig.default
        config.gaps = .init(inner: 8, outer: 8)
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.bottom = 43"))  // thickness 25 + 10 + outer 8
        config.statusBar.theme = .technical
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.bottom = 39"))  // technical: 25 + 6 + 8
        config.statusBar.enabled = false
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.bottom = 8"))
        // Only the bottom edge reserves bar space.
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.top = 8"))
    }

    @Test func hyperBaseComboExcludesShift() {
        let combo = AeroSpaceConfigEmitter.keyCombo(modifier: .hyper, key: "1")
        #expect(combo == "cmd-alt-ctrl-1")
    }

    @Test func shiftChordsStayDistinctFromBase() {
        let base = AeroSpaceConfigEmitter.keyCombo(modifier: .hyper, key: "1")
        let shifted = AeroSpaceConfigEmitter.keyCombo(modifier: .hyper, key: "shift-1")
        #expect(shifted == "cmd-alt-ctrl-shift-1")
        #expect(base != shifted)
    }

    @Test func emitsConfigVersion2WithPersistentWorkspaces() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("config-version = 2"))
        #expect(
            toml.contains(
                "persistent-workspaces = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']"))
    }

    @Test func omitsPersistentWorkspacesWhenNoWorkspaceBindings() {
        var config = PanewrightConfig.default
        config.bindings = [.init(key: "h", action: .focus(.left))]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(!toml.contains("persistent-workspaces"))
    }

    @Test func emitsI3StyleDefaultBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("alt-1 = 'summon-workspace 1'"))
        // Routed via move-window.sh so fullscreen windows move too.
        #expect(toml.contains("alt-shift-1 = 'exec-and-forget /bin/bash"))
        #expect(toml.contains("move-window.sh\" workspace 1'"))
        #expect(toml.contains("alt-h = 'focus left'"))
        #expect(toml.contains("alt-shift-l = 'move right'"))
        #expect(toml.contains("alt-e = 'layout tiles horizontal vertical'"))
        #expect(toml.contains("alt-s = 'layout accordion horizontal vertical'"))
    }

    @Test func emitsFloatingAppRules() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("[[on-window-detected]]"))
        #expect(toml.contains("if.app-id = 'com.apple.systempreferences'"))
        #expect(toml.contains("run = 'layout floating'"))
    }

    @Test func emitsResizeModeWithBareKeys() {
        var config = PanewrightConfig.default
        config.statusBar.enabled = false
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("alt-r = 'mode resize'"))
        #expect(toml.contains("[mode.resize.binding]"))
        #expect(toml.contains("h = 'resize width -50'"))
        #expect(toml.contains("j = 'resize height +50'"))
        #expect(toml.contains("esc = 'mode main'"))
    }

    @Test func emitsWindowAndMonitorBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("alt-f = 'fullscreen'"))
        #expect(toml.contains("alt-shift-space = 'layout floating tiling'"))
        #expect(toml.contains("alt-comma = 'focus-monitor --wrap-around left'"))
        #expect(toml.contains("move-window.sh\" monitor right'"))
        #expect(toml.contains("alt-enter = 'exec-and-forget open -a Terminal'"))
    }

    @Test func emitsWorkspaceMonitorAssignments() {
        var config = PanewrightConfig.default
        config.workspaceMonitors = [6: "secondary", 1: "main"]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("[workspace-to-monitor-force-assignment]"))
        #expect(toml.contains("1 = 'main'"))
        #expect(toml.contains("6 = 'secondary'"))
    }

    @Test func emitsCtrlAltAndCtrlCmdCombos() {
        #expect(AeroSpaceConfigEmitter.keyCombo(modifier: .ctrlAlt, key: "1") == "ctrl-alt-1")
        #expect(
            AeroSpaceConfigEmitter.keyCombo(modifier: .ctrlAlt, key: "shift-h")
                == "ctrl-alt-shift-h")
        #expect(AeroSpaceConfigEmitter.keyCombo(modifier: .ctrlCmd, key: "f") == "ctrl-cmd-f")
    }

    @Test func emitsLeaderStyleAsOneShotMode() {
        var config = PanewrightConfig.default
        config.modifier = .leader
        config.statusBar.enabled = false
        let toml = AeroSpaceConfigEmitter.emit(config)
        // The default leader is cmd-backtick (2026-07-27, dogfooded).
        #expect(toml.contains("cmd-backtick = 'mode panewright'"))
        #expect(toml.contains("[mode.panewright.binding]"))
        #expect(toml.contains("1 = ['summon-workspace 1', 'mode main']"))
        #expect(toml.contains("h = ['focus left', 'mode main']"))
        // Mode entries must not chain back to main, or the mode would be dead.
        #expect(toml.contains("r = 'mode resize'"))
        #expect(toml.contains("g = 'mode join'"))
        #expect(toml.contains("esc = 'mode main'"))
        // No held chords anywhere in leader style.
        #expect(!toml.contains("alt-1"))
    }

    @Test func emitsScratchpadBindingsAndAssignRules() {
        var config = PanewrightConfig.default
        config.statusBar.enabled = false
        config.appWorkspaces = ["com.apple.Music": 3]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(
            toml.contains(
                "alt-minus = 'exec-and-forget /bin/bash \"$HOME/.config/panewright/scripts/scratchpad-show.sh\"'"
            ))
        #expect(
            toml.contains(
                "alt-shift-minus = ['layout floating', 'move-node-to-workspace S']"))
        #expect(toml.contains("if.app-id = 'com.apple.Music'"))
        #expect(toml.contains("run = 'move-node-to-workspace 3'"))
    }

    @Test func emitsFlattenBinding() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("alt-shift-g = 'flatten-workspace-tree'"))
    }

    @Test func emitsWorkspaceCallbackAndModeTriggersWhenBarEnabled() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(
            toml.contains(
                "exec-on-workspace-change = ['/bin/bash', '-c', '\"$HOME\"/.config/panewright/scripts/on-workspace-change.sh']"
            ))
        #expect(
            toml.contains(
                "'mode join', 'exec-and-forget /opt/homebrew/bin/sketchybar --trigger panewright_mode MODE=join'"
            ))
        #expect(toml.contains("MODE=main"))
        // No focus-change trigger: bursts of focus events (permission dialogs)
        // spawned concurrent repaints that crashed SketchyBar. Occupancy
        // freshness comes from the driver's update_freq poll instead.
        #expect(!toml.contains("on-focus-changed"))
    }

    @Test func omitsBarPlumbingWhenBarDisabled() {
        var config = PanewrightConfig.default
        config.statusBar.enabled = false
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(!toml.contains("sketchybar"))
    }

    @Test func emitsJoinModeWithCommandChains() {
        var config = PanewrightConfig.default
        config.statusBar.enabled = false
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("alt-g = 'mode join'"))
        #expect(toml.contains("[mode.join.binding]"))
        #expect(toml.contains("h = ['join-with left', 'mode main']"))
        #expect(toml.contains("l = ['join-with right', 'mode main']"))
    }

    @Test func defaultsToTilesRootLayout() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("default-root-container-layout = 'tiles'"))
        #expect(toml.contains("enable-normalization-flatten-containers = true"))
    }
}

/// The scripting events that make hooks worth scripting against.
@Suite struct RicherHooksTests {
    @Test func modeChangedHookRidesTheModeChain() {
        var config = PanewrightConfig.default
        config.modeChangedHook = "~/bin/on-mode.sh"
        let toml = AeroSpaceConfigEmitter.emit(config)
        // Entering resize runs the user hook with MODE in the environment,
        // in the same chain as the mode switch itself.
        #expect(toml.contains("MODE=resize /bin/bash -c \"~/bin/on-mode.sh\""))
        #expect(toml.contains("MODE=join /bin/bash -c \"~/bin/on-mode.sh\""))
    }

    @Test func hooksRoundTripThroughTheConfigFile() throws {
        var config = PanewrightConfig.default
        config.windowOpenedHook = "echo opened"
        config.windowClosedHook = "echo closed"
        config.modeChangedHook = "echo mode"
        let parsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(parsed.windowOpenedHook == "echo opened")
        #expect(parsed.windowClosedHook == "echo closed")
        #expect(parsed.modeChangedHook == "echo mode")
    }

    @Test func noHooksMeansNoHookNoiseInTheEmit() {
        // The bar's own MODE= trigger is always there; the user-hook shell
        // invocation must not be.
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(!toml.contains("MODE=resize /bin/bash"))
    }
}
