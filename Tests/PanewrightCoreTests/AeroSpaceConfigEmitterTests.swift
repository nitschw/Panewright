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

    @Test func defaultsToTilesRootLayout() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("default-root-container-layout = 'tiles'"))
        #expect(toml.contains("enable-normalization-flatten-containers = true"))
    }
}
