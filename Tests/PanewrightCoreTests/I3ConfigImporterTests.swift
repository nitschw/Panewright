import Testing

@testable import PanewrightCore

@Suite struct I3ConfigImporterTests {
    let sample = """
        # i3 config file (v4)
        set $mod Mod4
        set $term alacritty
        font pango:monospace 8
        floating_modifier $mod
        bindsym $mod+Return exec i3-sensible-terminal
        bindsym $mod+Shift+q kill
        bindsym $mod+h focus left
        bindsym $mod+1 workspace number 1
        bindsym $mod+Shift+1 move container to workspace number 1
        bindsym $mod+v split v
        bindsym $mod+f fullscreen toggle
        bindsym $mod+Shift+space floating toggle
        bindsym $mod+w layout tabbed
        bindsym $mod+d exec dmenu_run
        bindsym $mod+minus scratchpad show
        bindsym $mod+r mode "resize"
        mode "resize" {
            bindsym h resize shrink width 10 px or 10 ppt
            bindsym l resize grow width 10 px or 10 ppt
            bindsym Return mode "default"
            bindsym Escape mode "default"
        }
        gaps inner 10
        gaps outer 4
        focus_follows_mouse yes
        client.focused #4c7899 #285577 #ffffff #2e9ef4 #285577
        for_window [class="Pavucontrol"] floating enable
        workspace 9 output HDMI-1
        bar {
            status_command i3status
            position top
        }
        """

    @Test func translatesCoreBindings() {
        let result = I3ConfigImporter.importConfig(sample)
        let bindings = result.config.bindings
        #expect(bindings.contains(.init(key: "enter", action: .exec("open -a Terminal"))))
        #expect(bindings.contains(.init(key: "shift-q", action: .close)))
        #expect(bindings.contains(.init(key: "h", action: .focus(.left))))
        #expect(bindings.contains(.init(key: "1", action: .workspace(1))))
        #expect(bindings.contains(.init(key: "shift-1", action: .moveToWorkspace(1))))
        #expect(bindings.contains(.init(key: "f", action: .fullscreen)))
        #expect(bindings.contains(.init(key: "shift-space", action: .toggleFloating)))
        #expect(bindings.contains(.init(key: "w", action: .layoutAccordion)))
        #expect(bindings.contains(.init(key: "r", action: .enterMode("resize"))))
        #expect(bindings.contains(.init(key: "minus", action: .scratchpadShow)))
    }

    @Test func translatesModesWithDefaultMappedToMain() {
        let result = I3ConfigImporter.importConfig(sample)
        let resize = result.config.modes.first { $0.name == "resize" }
        #expect(resize != nil)
        #expect(resize?.bindings.contains(.init(key: "h", action: .resize(.width, -10))) == true)
        #expect(resize?.bindings.contains(.init(key: "l", action: .resize(.width, 10))) == true)
        #expect(resize?.bindings.contains(.init(key: "enter", action: .enterMode("main"))) == true)
        // Panewright's join mode is appended as added value.
        #expect(result.config.modes.contains { $0.name == "join" })
    }

    @Test func importsGapsColorsAndWorkspaceMonitors() {
        let result = I3ConfigImporter.importConfig(sample)
        #expect(result.config.gaps == .init(inner: 10, outer: 4))
        #expect(result.config.focusBorder.activeColor == "#4c7899")
        #expect(result.config.workspaceMonitors[9] == "HDMI-1")
        #expect(result.config.modifier == .hyper)
        #expect(result.config.focusFollowsMouse == true)
        #expect(!result.issues.contains { $0.text.contains("focus_follows_mouse") })
    }

    @Test func flagsEverythingUntranslatableWithLineNumbers() {
        let result = I3ConfigImporter.importConfig(sample)
        let reasons = result.issues.map(\.reason).joined(separator: "\n")
        #expect(reasons.contains("font"))
        #expect(reasons.contains("floating_modifier"))
        #expect(reasons.contains("join mode"))  // split v
        #expect(!reasons.contains("scratchpad"))  // now supported
        #expect(reasons.contains("dmenu_run"))
        #expect(reasons.contains("i3bar"))
        #expect(reasons.contains("bundle ID"))  // for_window floating
        #expect(reasons.contains("monitor pattern"))  // workspace output
        let splitIssue = result.issues.first { $0.text.contains("split v") }
        #expect(splitIssue?.line == 11)
        // The bar block's contents are skipped without individual noise.
        #expect(!reasons.contains("status_command"))
    }

    @Test func mod1MapsToAlt() {
        let result = I3ConfigImporter.importConfig(
            "set $mod Mod1\nbindsym $mod+1 workspace number 1\n")
        #expect(result.config.modifier == .alt)
        #expect(result.config.bindings == [.init(key: "1", action: .workspace(1))])
    }

    @Test func importedConfigSerializesAndReparses() throws {
        let imported = I3ConfigImporter.importConfig(sample).config
        let toml = PanewrightConfigSerializer.emit(imported)
        let reparsed = try ConfigParser.parse(toml: toml)
        #expect(reparsed == imported)
    }
}

@Suite struct SerializerRoundTripTests {
    @Test func defaultConfigSurvivesRoundTrip() throws {
        let toml = PanewrightConfigSerializer.emit(.default)
        let reparsed = try ConfigParser.parse(toml: toml)
        #expect(reparsed == PanewrightConfig.default)
    }
}
