import Testing

@testable import PanewrightCore

@Suite struct SketchyBarConfigEmitterTests {
    @Test func nativeThemeEmitsBarAndWorkspaceItems() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("position=top"))
        #expect(files.sketchybarrc.contains("corner_radius=9"))
        #expect(files.sketchybarrc.contains("SF Pro"))
        #expect(files.sketchybarrc.contains("for sid in 1 2 3 4 5 6 7 8 9"))
        #expect(files.sketchybarrc.contains("aerospace workspace $sid"))
        #expect(files.sketchybarrc.contains("--add event panewright_mode"))
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

    @Test func emitsSystemStatusItems() throws {
        let files = try SketchyBarConfigEmitter.emit(.default)
        #expect(files.sketchybarrc.contains("panewright_battery.sh"))
        #expect(files.sketchybarrc.contains("panewright_wifi.sh"))
        #expect(files.batteryPlugin.contains("pmset -g batt"))
        #expect(files.wifiPlugin.contains("system_profiler SPAirPortDataType"))
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
