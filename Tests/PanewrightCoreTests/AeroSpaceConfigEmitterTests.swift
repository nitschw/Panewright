import Testing

@testable import PanewrightCore

@Suite struct AeroSpaceConfigEmitterTests {
    @Test func emitsGaps() {
        var config = PanewrightConfig.default
        config.gaps = .init(inner: 10, outer: 6)
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(toml.contains("inner.horizontal = 10"))
        #expect(toml.contains("inner.vertical = 10"))
        #expect(toml.contains("outer.top = 6"))
        #expect(toml.contains("outer.left = 6"))
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
                "persistent-workspaces = ['1', '2', '3', '4', '5', '6', '7', '8', '9']"))
    }

    @Test func omitsPersistentWorkspacesWhenNoWorkspaceBindings() {
        var config = PanewrightConfig.default
        config.bindings = [.init(key: "h", action: .focus(.left))]
        let toml = AeroSpaceConfigEmitter.emit(config)
        #expect(!toml.contains("persistent-workspaces"))
    }

    @Test func emitsI3StyleDefaultBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("cmd-alt-ctrl-1 = 'workspace 1'"))
        #expect(toml.contains("cmd-alt-ctrl-shift-1 = 'move-node-to-workspace 1'"))
        #expect(toml.contains("cmd-alt-ctrl-h = 'focus left'"))
        #expect(toml.contains("cmd-alt-ctrl-shift-l = 'move right'"))
        #expect(toml.contains("cmd-alt-ctrl-e = 'layout tiles horizontal vertical'"))
        #expect(toml.contains("cmd-alt-ctrl-s = 'layout accordion horizontal vertical'"))
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
        #expect(toml.contains("cmd-alt-ctrl-r = 'mode resize'"))
        #expect(toml.contains("[mode.resize.binding]"))
        #expect(toml.contains("h = 'resize width -50'"))
        #expect(toml.contains("j = 'resize height +50'"))
        #expect(toml.contains("esc = 'mode main'"))
    }

    @Test func emitsWindowAndMonitorBindings() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("cmd-alt-ctrl-f = 'fullscreen'"))
        #expect(toml.contains("cmd-alt-ctrl-shift-space = 'layout floating tiling'"))
        #expect(toml.contains("cmd-alt-ctrl-left = 'focus-monitor left'"))
        #expect(toml.contains("cmd-alt-ctrl-shift-right = 'move-node-to-monitor right'"))
        #expect(toml.contains("cmd-alt-ctrl-enter = 'exec-and-forget open -a Terminal'"))
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
        #expect(toml.contains("cmd-semicolon = 'mode panewright'"))
        #expect(toml.contains("[mode.panewright.binding]"))
        #expect(toml.contains("1 = ['workspace 1', 'mode main']"))
        #expect(toml.contains("h = ['focus left', 'mode main']"))
        // Mode entries must not chain back to main, or the mode would be dead.
        #expect(toml.contains("r = 'mode resize'"))
        #expect(toml.contains("g = 'mode join'"))
        #expect(toml.contains("esc = 'mode main'"))
        // No hyper chords anywhere in leader style.
        #expect(!toml.contains("cmd-alt-ctrl"))
    }

    @Test func emitsFlattenBinding() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("cmd-alt-ctrl-shift-g = 'flatten-workspace-tree'"))
    }

    @Test func emitsWorkspaceCallbackAndModeTriggersWhenBarEnabled() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(
            toml.contains(
                "exec-on-workspace-change = ['/bin/bash', '-c', '/opt/homebrew/bin/sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE']"
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
        #expect(toml.contains("cmd-alt-ctrl-g = 'mode join'"))
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
