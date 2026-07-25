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

    @Test func theSmallestObservationWins() {
        // A window can refuse to shrink because it was busy or animating, not
        // because it hit its floor. That reads as a *higher* minimum than the
        // truth, and keeping it would over-reserve space for that app forever.
        var store = MinimumSizeStore(file: temporaryFile())
        store.record(bundleID: "com.apple.Safari", minimum: 900)
        store.record(bundleID: "com.apple.Safari", minimum: 620)
        #expect(store.minimum(for: "com.apple.Safari") == 620)
        // And a later spurious refusal doesn't undo the correction.
        store.record(bundleID: "com.apple.Safari", minimum: 880)
        #expect(store.minimum(for: "com.apple.Safari") == 620)
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
