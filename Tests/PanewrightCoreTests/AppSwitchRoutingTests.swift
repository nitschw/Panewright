import Testing

@testable import PanewrightCore

private func window(_ id: UInt32, _ bundleID: String, _ workspace: String)
    -> AppSwitchRouting.Window
{
    AppSwitchRouting.Window(id: id, bundleID: bundleID, workspace: workspace)
}

/// Cmd+Tab activates an app; it knows nothing about workspaces or about
/// windows parked in the bar. These decide what activation should mean.
@Suite struct AppSwitchRoutingTests {
    private let windows = [
        window(1, "com.apple.Safari", "0"),
        window(2, "com.hnc.Discord", "P"),  // parked in the bar
        window(3, "com.googlecode.iterm2", "1"),
    ]

    @Test func anAppAlreadyOnScreenIsLeftAlone() {
        // macOS raising it is the whole job; moving anything would be
        // meddling with a window that's already in front of you.
        #expect(
            AppSwitchRouting.route(
                to: "com.apple.Safari", windows: windows, focusedWorkspace: "0") == .nothing)
    }

    @Test func aParkedWindowIsSummonedRatherThanLeftHidden() {
        // The reported bug: switching to Discord raised the app while its
        // window stayed on the hidden pills workspace, so you got an empty
        // workspace and still had to click the pill.
        #expect(
            AppSwitchRouting.route(
                to: "com.hnc.Discord", windows: windows, focusedWorkspace: "0")
                == .summonPill(id: 2))
    }

    @Test func anAppOnAnotherWorkspaceIsFollowedThere() {
        #expect(
            AppSwitchRouting.route(
                to: "com.googlecode.iterm2", windows: windows, focusedWorkspace: "0")
                == .focusWindow(id: 3))
    }

    @Test func parkedBeatsACopyOnAnotherWorkspace() {
        // Parking a window is a deliberate "keep this to hand", so summoning
        // it is closer to the intent than throwing the desktop to wherever
        // another window of the same app happens to live.
        let both = [
            window(2, "com.hnc.Discord", "P"),
            window(9, "com.hnc.Discord", "4"),
        ]
        #expect(
            AppSwitchRouting.route(to: "com.hnc.Discord", windows: both, focusedWorkspace: "0")
                == .summonPill(id: 2))
    }

    @Test func aVisibleWindowBeatsAParkedOneOfTheSameApp() {
        // One window here, another parked: you're looking at the app already,
        // so summoning the parked one would be an unrequested change.
        let both = [
            window(2, "com.hnc.Discord", "P"),
            window(9, "com.hnc.Discord", "0"),
        ]
        #expect(
            AppSwitchRouting.route(to: "com.hnc.Discord", windows: both, focusedWorkspace: "0")
                == .nothing)
    }

    @Test func anAppWithNoTiledWindowsIsLeftAlone() {
        // Preferences panels, menu-bar apps, an app launching with no window
        // yet. Nothing to route to, and inventing a move would be worse.
        #expect(
            AppSwitchRouting.route(
                to: "com.apple.systempreferences", windows: windows, focusedWorkspace: "0")
                == .nothing)
    }

    @Test func anEmptyWorldRoutesNowhere() {
        #expect(
            AppSwitchRouting.route(to: "com.apple.Safari", windows: [], focusedWorkspace: "0")
                == .nothing)
    }

    @Test func switchingWhileOnThePillsWorkspaceStillWorks() {
        // Edge case worth pinning: if the focused workspace somehow *is* the
        // pills workspace, a parked window counts as already visible.
        #expect(
            AppSwitchRouting.route(
                to: "com.hnc.Discord", windows: windows, focusedWorkspace: "P") == .nothing)
    }
}

@Suite struct FollowAppSwitchConfigTests {
    @Test func theSettingSurvivesTheConfigFile() throws {
        var config = PanewrightConfig.default
        config.followAppSwitch = false
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.followAppSwitch == false)
    }

    @Test func itIsOnByDefault() {
        #expect(PanewrightConfig().followAppSwitch)
    }

    @Test func anOlderConfigWithoutTheKeyStillLoads() throws {
        #expect(try ConfigParser.parse(toml: "modifier = \"alt\"\n").followAppSwitch)
    }
}
