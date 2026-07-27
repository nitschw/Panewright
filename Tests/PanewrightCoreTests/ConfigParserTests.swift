import Testing

@testable import PanewrightCore

@Suite struct ConfigParserTests {
    @Test func parsesNewPassthroughActions() throws {
        // Each exposes an AeroSpace command that had no binding before.
        let cases: [(String, PanewrightConfig.Action, String)] = [
            ("balance", .balanceSizes, "balance-sizes"),
            ("fullscreen native", .nativeFullscreen, "macos-native-fullscreen"),
            ("minimize", .minimize, "macos-native-minimize"),
            ("close others", .closeOthers, "close-all-windows-but-current"),
            ("focus back_and_forth", .focusBackAndForth, "focus-back-and-forth"),
            (
                "move workspace to monitor next", .moveWorkspaceToMonitor(.next),
                "move-workspace-to-monitor next"
            ),
        ]
        for (text, action, command) in cases {
            #expect(try ConfigParser.parseAction(text) == action)
            // Serializer round-trips back to the same spelling.
            #expect(PanewrightConfigSerializer.actionString(action) == text)
            // Emitter maps to the right AeroSpace command.
            #expect(AeroSpaceConfigEmitter.command(for: action) == command)
        }
        // `close others` must not collide with `close`.
        #expect(try ConfigParser.parseAction("close") == .close)
    }

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

    @Test func parsesFocusFollowsMouse() throws {
        let config = try ConfigParser.parse(toml: "focus-follows-mouse = true\n")
        #expect(config.focusFollowsMouse == true)
        #expect(PanewrightConfig.default.focusFollowsMouse == false)
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
            action = "focus parent"
            """
        #expect(throws: ConfigError.invalidAction("focus parent")) {
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
        #expect(emitted.contains("cmd-alt-ctrl-3 = 'summon-workspace 3'"))
    }
}

/// The contract behind "my setup is what new users get": the file a fresh
/// install writes must parse to exactly the built-in defaults — which are the
/// dogfooded configuration (2026-07-27). Any drift between the template and
/// the defaults breaks the promise silently, so it breaks here instead.
@Suite struct FreshInstallTests {
    @Test func theFirstRunTemplateParsesToTheDefaults() throws {
        let parsed = try ConfigParser.parse(toml: Orchestrator.defaultConfigTemplate)
        #expect(parsed == PanewrightConfig.default)
    }

    @Test func theDefaultsSerializeWithoutPinningTheKeymap() {
        // No [[binding]] blocks in what the editor would save for a default
        // config — a frozen keymap snapshot is how one machine stopped
        // receiving new default bindings for weeks.
        let toml = PanewrightConfigSerializer.emit(.default)
        #expect(!toml.contains("[[binding]]"))
    }
}

/// The v0.5 additions: palette, overview, dropdown.
@Suite struct PostLaunchFeatureConfigTests {
    @Test func newActionsRoundTrip() throws {
        for name in ["launcher", "overview", "dropdown"] {
            let toml = "[[binding]]\nkey = \"z\"\naction = \"\(name)\""
            let parsed = try ConfigParser.parse(toml: toml)
            let out = PanewrightConfigSerializer.emit(parsed)
            #expect(out.contains("action = \"\(name)\""))
        }
    }

    @Test func newDefaultsCarryTheTrioAndEmitDeepLinks() {
        let toml = AeroSpaceConfigEmitter.emit(.default)
        #expect(toml.contains("alt-d = 'exec-and-forget open -g panewright://launcher'"))
        #expect(toml.contains("alt-o = 'exec-and-forget open -g panewright://overview'"))
        #expect(toml.contains("alt-backtick = 'exec-and-forget open -g panewright://dropdown'"))
    }

    @Test func dropdownConfigRoundTrips() throws {
        var config = PanewrightConfig.default
        config.dropdown.app = "com.mitchellh.ghostty"
        config.dropdown.height = 0.5
        let parsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(parsed.dropdown.app == "com.mitchellh.ghostty")
        #expect(parsed.dropdown.height == 0.5)
        #expect(parsed.dropdown.enabled)
    }

    @Test func dropdownHeightIsClamped() throws {
        let parsed = try ConfigParser.parse(toml: "[dropdown]\nheight = 3.0")
        #expect(parsed.dropdown.height == 0.9)
    }
}
