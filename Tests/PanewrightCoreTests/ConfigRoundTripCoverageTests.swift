import Testing

@testable import PanewrightCore

/// The editor's save path is serialize → write → reparse. Anything the
/// serializer drops is an edit that silently vanishes the next time the config
/// is read — the worst possible failure for a settings GUI, since it looks
/// like it worked. Now that the editor can reach every field, every field has
/// to survive the trip.
@Suite struct ConfigRoundTripCoverageTests {
    private var populated: PanewrightConfig {
        var config = PanewrightConfig.default
        config.modifier = .alt
        config.leaderKey = "cmd-backtick"
        config.focusFollowsMouse = true
        config.workspaceChangedHook = "python3 ~/hooks/ws.py"
        config.focusChangedHook = "echo $FOCUSED_APP"
        config.statusBar.accentColor = "#FF8800"
        config.todo.enabled = true
        config.pills.enabled = true
        config.pills.dragToBar = false
        config.fitting = PanewrightConfig.Fitting(enabled: true, overflow: false, step: 35)
        config.workspaceMonitors = [1: "main", 2: "secondary", 7: "DELL.*"]
        config.appWorkspaces = ["com.apple.Safari": 2, "com.hnc.Discord": 5]
        config.floatingApps = ["com.apple.systempreferences"]
        config.modes = [
            .init(
                name: "resize",
                bindings: [
                    .init(key: "h", action: .resize(.width, -50)),
                    .init(key: "l", action: .resize(.width, 50)),
                ])
        ]
        return config
    }

    @Test func everySettingTheEditorCanReachSurvivesTheFile() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))

        #expect(reparsed.modifier == .alt)
        #expect(reparsed.leaderKey == "cmd-backtick")
        #expect(reparsed.focusFollowsMouse)
        #expect(reparsed.floatingApps == ["com.apple.systempreferences"])
    }

    @Test func hooksSurvive() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed.workspaceChangedHook == "python3 ~/hooks/ws.py")
        #expect(reparsed.focusChangedHook == "echo $FOCUSED_APP")
    }

    @Test func theBarAccentColorSurvives() throws {
        // Supported by the config and the emitter, but reachable from nothing
        // until the Appearance tab — so this path had never been exercised.
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed.statusBar.accentColor == "#FF8800")

        // And nil has to stay nil, since that's what "follow the border" means.
        var unset = populated
        unset.statusBar.accentColor = nil
        let reparsedUnset = try ConfigParser.parse(
            toml: PanewrightConfigSerializer.emit(unset))
        #expect(reparsedUnset.statusBar.accentColor == nil)
    }

    @Test func workspaceAndAppAssignmentsSurvive() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed.workspaceMonitors == [1: "main", 2: "secondary", 7: "DELL.*"])
        #expect(reparsed.appWorkspaces == ["com.apple.Safari": 2, "com.hnc.Discord": 5])
    }

    @Test func modesAndTheirBindingsSurvive() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed.modes.count == 1)
        #expect(reparsed.modes.first?.name == "resize")
        #expect(reparsed.modes.first?.bindings.count == 2)
        #expect(reparsed.modes.first?.bindings.first?.key == "h")
    }

    @Test func companionTogglesSurvive() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed.todo.enabled)
        #expect(reparsed.pills.enabled)
        #expect(reparsed.pills.dragToBar == false)
    }

    @Test func widgetOrderSurvives() throws {
        var config = populated
        var order = config.modules.resolvedOrder
        order.swapAt(0, 1)
        config.modules.order = order
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.modules.resolvedOrder == order)
    }

    /// The whole config, not field by field — catches anything added later
    /// that nobody remembered to serialize.
    @Test func theWholeConfigIsUnchangedByARoundTrip() throws {
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(populated))
        #expect(reparsed == populated)
    }

    @Test func aCustomLeaderKeySurvivesChangingTheModKeyAndChangingItBack() throws {
        // The trap this closes: leader-key used to be written only while
        // `modifier = "leader"` was selected. Switching the mod key in the
        // editor to try something else and switching back would silently
        // replace a custom leader key with the default — a setting lost by
        // looking at it.
        var config = PanewrightConfig.default
        config.modifier = .leader
        config.leaderKey = "cmd-backtick"

        var switchedAway = try ConfigParser.parse(
            toml: PanewrightConfigSerializer.emit(config))
        switchedAway.modifier = .ctrlCmd
        let whileAway = try ConfigParser.parse(
            toml: PanewrightConfigSerializer.emit(switchedAway))
        #expect(whileAway.leaderKey == "cmd-backtick")

        var switchedBack = whileAway
        switchedBack.modifier = .leader
        let returned = try ConfigParser.parse(
            toml: PanewrightConfigSerializer.emit(switchedBack))
        #expect(returned.leaderKey == "cmd-backtick")
    }

    @Test func topLevelKeysAreNotSwallowedByATableAboveThem() throws {
        // TOML scopes a bare key to the table header preceding it. floating-apps
        // and ignored-conflicts were emitted after [hooks], so any config with
        // a hook set read them back as hooks.floating-apps — and lost them.
        var config = PanewrightConfig.default
        config.workspaceChangedHook = "true"
        config.floatingApps = ["com.apple.systempreferences"]
        config.ignoredConflicts = ["main/f/system"]

        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.floatingApps == ["com.apple.systempreferences"])
        #expect(reparsed.ignoredConflicts == ["main/f/system"])
        #expect(reparsed.workspaceChangedHook == "true")
    }

    @Test func everyTopLevelKeyPrecedesTheFirstTableHeader() {
        // Structural guard, so the next top-level key added doesn't have to
        // rediscover this the hard way.
        var config = PanewrightConfig.default
        config.workspaceChangedHook = "true"
        config.floatingApps = ["com.example.app"]
        config.ignoredConflicts = ["main/f/system"]
        let lines = PanewrightConfigSerializer.emit(config).split(separator: "\n")

        let firstTable = lines.firstIndex { $0.hasPrefix("[") } ?? lines.count
        for (index, line) in lines.enumerated() where index > firstTable {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Inside a table, the only bare keys allowed are that table's own.
            guard trimmed.contains("="), !trimmed.hasPrefix("#") else { continue }
            #expect(
                !trimmed.hasPrefix("floating-apps"),
                "floating-apps must precede the first [table]")
            #expect(
                !trimmed.hasPrefix("ignored-conflicts"),
                "ignored-conflicts must precede the first [table]")
        }
    }
}
