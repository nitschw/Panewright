import Testing

@testable import PanewrightCore

@Suite struct ConfigParserTests {
    @Test func parsesFullConfig() throws {
        let toml = """
            modifier = "alt"

            [gaps]
            inner = 12
            outer = 4

            [border]
            width = 2
            active-color = "#FF0000"

            [[binding]]
            key = "1"
            action = "workspace 1"

            [[binding]]
            key = "shift-2"
            action = "move to workspace 2"

            [[binding]]
            key = "h"
            action = "focus left"

            [[binding]]
            key = "shift-l"
            action = "move right"
            """
        let config = try ConfigParser.parse(toml: toml)
        #expect(config.modifier == .alt)
        #expect(config.gaps == .init(inner: 12, outer: 4))
        #expect(config.focusBorder.width == 2)
        #expect(config.focusBorder.activeColor == "#FF0000")
        #expect(
            config.bindings == [
                .init(key: "1", action: .workspace(1)),
                .init(key: "shift-2", action: .moveToWorkspace(2)),
                .init(key: "h", action: .focus(.left)),
                .init(key: "shift-l", action: .move(.right)),
            ])
    }

    @Test func emptyConfigFallsBackToDefaults() throws {
        let config = try ConfigParser.parse(toml: "")
        #expect(config == .default)
    }

    @Test func parsesLayoutActions() throws {
        #expect(try ConfigParser.parseAction("layout tiles") == .layoutTiles)
        #expect(try ConfigParser.parseAction("layout accordion") == .layoutAccordion)
    }

    @Test func parsesJoinAndActionChains() throws {
        #expect(try ConfigParser.parseAction("join left") == .joinWith(.left))
        #expect(
            try ConfigParser.parseActionChain("join down; mode main")
                == [.joinWith(.down), .enterMode("main")])
        let toml = """
            [[binding]]
            key = "t"
            action = "workspace 4; layout accordion"
            """
        let config = try ConfigParser.parse(toml: toml)
        #expect(
            config.bindings == [
                .init(key: "t", actions: [.workspace(4), .layoutAccordion])
            ])
    }

    @Test func parsesWindowMonitorAndModeActions() throws {
        #expect(try ConfigParser.parseAction("fullscreen") == .fullscreen)
        #expect(try ConfigParser.parseAction("floating toggle") == .toggleFloating)
        #expect(try ConfigParser.parseAction("focus monitor next") == .focusMonitor(.next))
        #expect(try ConfigParser.parseAction("move to monitor left") == .moveToMonitor(.left))
        #expect(try ConfigParser.parseAction("resize width -50") == .resize(.width, -50))
        #expect(try ConfigParser.parseAction("resize height +50") == .resize(.height, 50))
        #expect(try ConfigParser.parseAction("mode resize") == .enterMode("resize"))
        #expect(try ConfigParser.parseAction("exec open -a iTerm") == .exec("open -a iTerm"))
    }

    @Test func parsesFloatingAppsAndMonitorAssignments() throws {
        let toml = """
            floating-apps = ["com.example.foo"]

            [workspace-monitors]
            1 = "main"
            6 = "secondary"
            """
        let config = try ConfigParser.parse(toml: toml)
        #expect(config.floatingApps == ["com.example.foo"])
        #expect(config.workspaceMonitors == [1: "main", 6: "secondary"])
    }

    @Test func rejectsNonNumericWorkspaceMonitorKey() {
        let toml = """
            [workspace-monitors]
            one = "main"
            """
        #expect(throws: ConfigError.invalidWorkspaceNumber("one")) {
            try ConfigParser.parse(toml: toml)
        }
    }

    @Test func parsesLeaderModifierAndKey() throws {
        let config = try ConfigParser.parse(
            toml: "modifier = \"leader\"\nleader-key = \"cmd-slash\"")
        #expect(config.modifier == .leader)
        #expect(config.leaderKey == "cmd-slash")
    }

    @Test func rejectsUnknownModifier() {
        #expect(throws: ConfigError.invalidModifier("super")) {
            try ConfigParser.parse(toml: "modifier = \"super\"")
        }
    }

    @Test func rejectsUnknownAction() {
        let toml = """
            [[binding]]
            key = "x"
            action = "scratchpad show"
            """
        #expect(throws: ConfigError.invalidAction("scratchpad show")) {
            try ConfigParser.parse(toml: toml)
        }
    }

    @Test func parsedConfigEmitsValidBindings() throws {
        let toml = """
            modifier = "hyper"

            [[binding]]
            key = "3"
            action = "workspace 3"
            """
        let config = try ConfigParser.parse(toml: toml)
        let emitted = AeroSpaceConfigEmitter.emit(config)
        #expect(emitted.contains("cmd-alt-ctrl-3 = 'workspace 3'"))
    }
}
