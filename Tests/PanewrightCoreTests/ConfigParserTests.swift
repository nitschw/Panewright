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

    @Test func rejectsUnknownModifier() {
        #expect(throws: ConfigError.invalidModifier("super")) {
            try ConfigParser.parse(toml: "modifier = \"super\"")
        }
    }

    @Test func rejectsUnknownAction() {
        let toml = """
            [[binding]]
            key = "x"
            action = "exec i3-sensible-terminal"
            """
        #expect(throws: ConfigError.invalidAction("exec i3-sensible-terminal")) {
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
