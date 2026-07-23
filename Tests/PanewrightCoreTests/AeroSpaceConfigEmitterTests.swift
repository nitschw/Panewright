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

    @Test func statusBarBecomesTheTopEdge() {
        var config = PanewrightConfig.default
        config.gaps = .init(inner: 8, outer: 8)
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.top = 48"))
        config.statusBar.theme = .technical
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.top = 40"))
        config.statusBar.enabled = false
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.top = 8"))
        // Only the top edge reserves bar space.
        #expect(AeroSpaceConfigEmitter.emit(config).contains("outer.bottom = 8"))
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
                "persistent-workspaces = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']"))
    }

    @Test func omitsPersistentWorkspacesWhenNoWorkspaceBindings() {
        var config = PanewrightConfig.default
        config.bindings = [.init(key: "h", action: .focus(.left))]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(!toml.contains("persistent-workspaces"))
    }

    @Test func emitsI3StyleDefaultBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("ctrl-cmd-1 = 'workspace 1'"))
        #expect(toml.contains("ctrl-cmd-shift-1 = 'move-node-to-workspace 1'"))
        #expect(toml.contains("ctrl-cmd-h = 'focus left'"))
        #expect(toml.contains("ctrl-cmd-shift-l = 'move right'"))
        #expect(toml.contains("ctrl-cmd-e = 'layout tiles horizontal vertical'"))
        #expect(toml.contains("ctrl-cmd-s = 'layout accordion horizontal vertical'"))
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
        #expect(toml.contains("ctrl-cmd-r = 'mode resize'"))
        #expect(toml.contains("[mode.resize.binding]"))
        #expect(toml.contains("h = 'resize width -50'"))
        #expect(toml.contains("j = 'resize height +50'"))
        #expect(toml.contains("esc = 'mode main'"))
    }

    @Test func emitsWindowAndMonitorBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("ctrl-cmd-f = 'fullscreen'"))
        #expect(toml.contains("ctrl-cmd-shift-space = 'layout floating tiling'"))
        #expect(toml.contains("ctrl-cmd-left = 'focus-monitor left'"))
        #expect(toml.contains("ctrl-cmd-shift-right = 'move-node-to-monitor right'"))
        #expect(toml.contains("ctrl-cmd-enter = 'exec-and-forget open -a Terminal'"))
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
        #expect(toml.contains("ctrl-cmd-space = 'mode panewright'"))
        #expect(toml.contains("[mode.panewright.binding]"))
        #expect(toml.contains("1 = ['workspace 1', 'mode main']"))
        #expect(toml.contains("h = ['focus left', 'mode main']"))
        // Mode entries must not chain back to main, or the mode would be dead.
        #expect(toml.contains("r = 'mode resize'"))
        #expect(toml.contains("g = 'mode join'"))
        #expect(toml.contains("esc = 'mode main'"))
        // No held chords anywhere in leader style.
        #expect(!toml.contains("ctrl-cmd-1"))
    }

    @Test func emitsScratchpadBindingsAndAssignRules() {
        var config = PanewrightConfig.default
        config.statusBar.enabled = false
        config.appWorkspaces = ["com.apple.Music": 3]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(
            toml.contains(
                "ctrl-cmd-minus = 'exec-and-forget /bin/bash \"$HOME/.config/panewright/scripts/scratchpad-show.sh\"'"
            ))
        #expect(
            toml.contains(
                "ctrl-cmd-shift-minus = ['layout floating', 'move-node-to-workspace S']"))
        #expect(toml.contains("if.app-id = 'com.apple.Music'"))
        #expect(toml.contains("run = 'move-node-to-workspace 3'"))
    }

    @Test func emitsFlattenBinding() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("ctrl-cmd-shift-g = 'flatten-workspace-tree'"))
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
        #expect(toml.contains("ctrl-cmd-g = 'mode join'"))
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
