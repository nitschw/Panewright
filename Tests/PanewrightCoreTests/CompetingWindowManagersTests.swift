import Testing

@testable import PanewrightCore

/// This check refuses to start the app, so a false positive costs someone
/// their window manager entirely. The tests are mostly about what must *not*
/// trip it.
@Suite struct CompetingWindowManagersTests {
    @Test func aRunningTilingManagerIsFound() {
        let found = CompetingWindowManagers.running(
            bundleIDs: ["com.amethyst.Amethyst", "com.apple.Safari"], processNames: [])
        #expect(found.map(\.name) == ["Amethyst"])
    }

    @Test func commandLineDaemonsAreMatchedByProcessName() {
        // yabai has no bundle ID, so bundle-only matching would miss the one
        // tool most likely to be fighting us.
        let found = CompetingWindowManagers.running(
            bundleIDs: [], processNames: ["yabai"])
        #expect(found.map(\.name) == ["yabai"])
    }

    @Test func aeroSpaceIsNeverACompetitor() {
        // Panewright supervises AeroSpace, so finding it running is the
        // expected state. Blocking on it would make the app refuse to start
        // whenever it had previously succeeded.
        #expect(!CompetingWindowManagers.known.contains { $0.name.lowercased().contains("aerospace") })
        let found = CompetingWindowManagers.running(
            bundleIDs: ["bobko.aerospace"], processNames: ["aerospace", "AeroSpace"])
        #expect(found.isEmpty)
    }

    @Test func launchersAndAutomationToolsDoNotBlockStartup() {
        // Raycast, Alfred, Hammerspoon and BetterTouchTool can all move a
        // window, but only when asked — they don't run a layout engine. Lots
        // of people have them, and refusing to launch would be wrong for
        // nearly all of those people.
        let found = CompetingWindowManagers.running(
            bundleIDs: [
                "com.raycast.macos", "com.runningwithcrayons.Alfred",
                "org.hammerspoon.Hammerspoon", "com.hegenberg.BetterTouchTool",
            ],
            processNames: ["hammerspoon", "skhd"])
        #expect(found.isEmpty)
    }

    @Test func nothingRunningMeansNothingToReport() {
        #expect(
            CompetingWindowManagers.running(bundleIDs: [], processNames: []).isEmpty)
    }

    @Test func severalAtOnceAreAllNamed() {
        let found = CompetingWindowManagers.running(
            bundleIDs: ["com.knollsoft.Rectangle", "com.crowdcafe.windowmagnet"],
            processNames: ["yabai"])
        #expect(found.count == 3)
    }

    @Test func theExplanationNamesTheToolAndTheWayOut() {
        let tools = CompetingWindowManagers.running(
            bundleIDs: ["com.amethyst.Amethyst"], processNames: [])
        let message = CompetingWindowManagers.explanation(for: tools)
        #expect(message.contains("Amethyst"))
        // A blocked launch has to say what to do about it, or it's just a wall.
        #expect(message.contains("Quit"))
        #expect(message.contains("Restart Environment"))
    }

    @Test func severalToolsReadAsOneSentence() {
        let tools = CompetingWindowManagers.running(
            bundleIDs: ["com.knollsoft.Rectangle"], processNames: ["yabai"])
        let message = CompetingWindowManagers.explanation(for: tools)
        #expect(message.contains("yabai"))
        #expect(message.contains("Rectangle"))
        #expect(message.contains("are running"))
    }

    @Test func everyEntryExplainsItselfAndIsIdentifiable() {
        for tool in CompetingWindowManagers.known {
            #expect(!tool.note.isEmpty, "\(tool.name) has no explanation")
            #expect(
                tool.bundleID != nil || tool.processName != nil,
                "\(tool.name) can never be detected")
        }
    }
}
