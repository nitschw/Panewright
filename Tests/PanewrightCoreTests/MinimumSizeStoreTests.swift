import CoreGraphics
import Foundation
import Testing

@testable import PanewrightCore

@Suite struct MinimumSizeStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "panewright-min-\(UUID().uuidString).json")
    }

    @Test func aLearnedFloorSurvivesARestart() throws {
        // Learning costs a visible resize, so it has to be worth doing once.
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var store = MinimumSizeStore(file: file)
        store.record(bundleID: "com.hnc.Discord", minimum: 940)
        store.save()

        var reloaded = MinimumSizeStore(file: file)
        reloaded.load()
        #expect(reloaded.minimum(for: "com.hnc.Discord") == 940)
    }

    @Test func theLatestRefusalWins() {
        // An app's minimum is not a constant. Safari's changes with its
        // sidebar and content — measured at 574 one hour and 753 the next.
        // Keeping the smallest ever seen threw away every fresh, correct
        // measurement, so the fitter believed a window could shrink further
        // than it could: it asked, was refused, and burned its attempt budget
        // instead of concluding the windows genuinely don't fit.
        var store = MinimumSizeStore(file: temporaryFile())
        store.record(bundleID: "com.apple.Safari", minimum: 574)
        store.record(bundleID: "com.apple.Safari", minimum: 753)
        #expect(store.minimum(for: "com.apple.Safari") == 753)
    }

    @Test func seeingAWindowSmallerThanItsFloorCorrectsTheFloor() {
        // The counterweight to trusting the latest refusal: a window can
        // decline for reasons that aren't its minimum, and without this the
        // estimate would ratchet upward forever. Sitting at 600 points is
        // proof the minimum is no more than 600.
        var store = MinimumSizeStore(file: temporaryFile())
        store.record(bundleID: "com.apple.Safari", minimum: 900)
        store.observe(bundleID: "com.apple.Safari", axis: .horizontal, size: 600)
        #expect(store.minimum(for: "com.apple.Safari") == 600)
    }

    @Test func seeingAWindowLargerThanItsFloorProvesNothing() {
        // A window being wide says nothing about how narrow it could go.
        var store = MinimumSizeStore(file: temporaryFile())
        store.record(bundleID: "com.apple.Safari", minimum: 600)
        store.observe(bundleID: "com.apple.Safari", axis: .horizontal, size: 1200)
        #expect(store.minimum(for: "com.apple.Safari") == 600)
    }

    @Test func observingAnAppWeKnowNothingAboutStaysUnknown() {
        // Absent means "worth asking". Recording a size as though it were a
        // floor would invent a constraint the app never expressed.
        var store = MinimumSizeStore(file: temporaryFile())
        store.observe(bundleID: "com.example.new", axis: .horizontal, size: 800)
        #expect(store.minimum(for: "com.example.new") == nil)
    }

    @Test func anUnknownAppIsNotAssumedConstrained() {
        // nil means "worth asking", which is what makes the first shrink
        // attempt happen at all.
        let store = MinimumSizeStore(file: temporaryFile())
        #expect(store.minimum(for: "com.example.never-seen") == nil)
    }

    @Test func aMissingCacheIsNotAnError() {
        // Losing it costs a few resizes to relearn, never correctness.
        var store = MinimumSizeStore(file: temporaryFile())
        store.load()
        #expect(store.widths.isEmpty)
    }
}

@Suite struct FittingConfigTests {
    @Test func fittingSettingsSurviveTheConfigFile() throws {
        var config = PanewrightConfig.default
        config.fitting = PanewrightConfig.Fitting(enabled: true, overflow: false, step: 45)
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.fitting.overflow == false)
        #expect(reparsed.fitting.step == 45)
        #expect(reparsed.fitting.enabled == true)
    }

    @Test func overflowIsOnByDefaultButNeverSilent() {
        // The default was chosen deliberately: overlapping windows are broken
        // tiling, so correcting it out of the box is right — provided the
        // controller always announces an eviction, which is its job.
        let fitting = PanewrightConfig.Fitting()
        #expect(fitting.enabled)
        #expect(fitting.overflow)
    }

    @Test func anOlderConfigWithoutTheSectionStillLoads() throws {
        // Upgrading must not require a config rewrite.
        let toml = """
            modifier = "alt"
            [gaps]
            inner = 8
            outer = 8
            """
        let config = try ConfigParser.parse(toml: toml)
        #expect(config.fitting == PanewrightConfig.Fitting())
    }
}

@Suite struct FloatOnTopConfigTests {
    @Test func theSettingSurvivesTheConfigFile() throws {
        var config = PanewrightConfig.default
        config.fitting.floatOnTop = false
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.fitting.floatOnTop == false)
    }

    @Test func floatingWindowsRideOnTopByDefault() {
        // It's what i3 does, and it's the reason floating a window is useful.
        #expect(PanewrightConfig.Fitting().floatOnTop)
    }

    @Test func anOlderConfigWithoutTheKeyStillLoads() throws {
        let toml = """
            modifier = "alt"
            [fitting]
            enabled = true
            """
        #expect(try ConfigParser.parse(toml: toml).fitting.floatOnTop)
    }
}

/// A floor near the size of the display is the signature of a resize that did
/// nothing, not of an app with an enormous minimum — and keeping one makes the
/// fitter believe the layout is impossible.
@Suite struct ImplausibleMinimumTests {
    @Test func floorsNearTheDisplaySizeAreDiscarded() {
        var store = MinimumSizeStore(
            file: FileManager.default.temporaryDirectory.appending(path: "t.json"),
            widths: ["real": 600, "phantom": 1671],
            heights: ["phantom": 1045])
        store.discardImplausible(displayWidth: 1728, displayHeight: 1117)
        // 1671 is 97% of the display; 1045 is 94% of its height.
        #expect(store.minimum(for: "phantom", axis: .horizontal) == nil)
        #expect(store.minimum(for: "phantom", axis: .vertical) == nil)
        // A genuine measurement is untouched.
        #expect(store.minimum(for: "real") == 600)
    }

    @Test func aLargeButBelievableFloorSurvives() {
        var store = MinimumSizeStore(
            file: FileManager.default.temporaryDirectory.appending(path: "t.json"),
            widths: ["chunky": 1200])
        store.discardImplausible(displayWidth: 1728, displayHeight: 1117)
        // 69% of the display — big, but apps like that genuinely exist.
        #expect(store.minimum(for: "chunky") == 1200)
    }
}
