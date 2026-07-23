import Testing

@testable import PanewrightCore

@Suite struct ColorHexTests {
    @Test func sixDigitHexGetsOpaqueAlpha() throws {
        #expect(try ColorHex.argb(fromCSSHex: "#0A84FF") == 0xFF0A_84FF)
    }

    @Test func eightDigitHexMovesAlphaInFront() throws {
        #expect(try ColorHex.argb(fromCSSHex: "#12345678") == 0x7812_3456)
        #expect(try ColorHex.argb(fromCSSHex: "#00000000") == 0x0000_0000)
    }

    @Test func rejectsMalformedColors() {
        #expect(throws: ConfigError.invalidColor("red")) {
            try ColorHex.argb(fromCSSHex: "red")
        }
        #expect(throws: ConfigError.invalidColor("0A84FF")) {
            try ColorHex.argb(fromCSSHex: "0A84FF")
        }
        #expect(throws: ConfigError.invalidColor("#0A84")) {
            try ColorHex.argb(fromCSSHex: "#0A84")
        }
    }
}

@Suite struct JankyBordersEmitterTests {
    @Test func emitsDefaultBorderArguments() throws {
        let args = try JankyBordersEmitter.arguments(for: .init())
        #expect(args.contains("active_color=0xff0a84ff"))
        #expect(args.contains("inactive_color=0x00000000"))
        #expect(args.contains("width=4.0"))
        #expect(args.contains("style=round"))
    }
}

@Suite struct BorderConfigParsingTests {
    @Test func parsesEnabledFlag() throws {
        let config = try ConfigParser.parse(
            toml: """
                [border]
                enabled = false
                """)
        #expect(config.focusBorder.enabled == false)
    }

    @Test func rejectsInvalidColorAtParseTime() {
        let toml = """
            [border]
            active-color = "blue"
            """
        #expect(throws: ConfigError.invalidColor("blue")) {
            try ConfigParser.parse(toml: toml)
        }
    }
}
