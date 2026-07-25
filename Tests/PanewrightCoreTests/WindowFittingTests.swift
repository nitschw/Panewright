import CoreGraphics
import Foundation
import Testing

@testable import PanewrightCore

private func window(
    _ id: UInt32, _ bundleID: String, x: CGFloat, width: CGFloat, arrived: TimeInterval = 0
) -> WindowFitting.Window {
    WindowFitting.Window(
        id: id, bundleID: bundleID,
        frame: CGRect(x: x, y: 0, width: width, height: 1000),
        arrived: Date(timeIntervalSince1970: arrived))
}

@Suite struct WindowOverlapTests {
    @Test func aTiledRowIsNotAnOverlap() {
        // Three windows side by side with gaps — the normal, working case.
        let windows = [
            window(1, "a", x: 0, width: 600),
            window(2, "b", x: 608, width: 500),
            window(3, "c", x: 1116, width: 570),
        ]
        #expect(WindowFitting.overlaps(in: windows).isEmpty)
    }

    @Test func aWindowRenderingOverItsNeighborIs() {
        // iTerm was given 400pt but won't go below 520, so it runs 120pt into
        // Safari's slot — the exact failure this whole file exists for.
        let windows = [
            window(1, "a", x: 0, width: 600),
            window(2, "iterm", x: 608, width: 520),
            window(3, "safari", x: 1008, width: 570),
        ]
        let overlaps = WindowFitting.overlaps(in: windows)
        #expect(overlaps.count == 1)
        #expect(overlaps.first?.0 == 2)
        #expect(overlaps.first?.1 == 3)
    }

    @Test func aSharedEdgeIsNotOverlap() {
        // Gap division leaves fractional frames; a window touching its
        // neighbor's edge is a rounding artifact, not broken tiling.
        let windows = [
            window(1, "a", x: 0, width: 600),
            window(2, "b", x: 599, width: 500),
        ]
        #expect(WindowFitting.overlaps(in: windows).isEmpty)
    }
}

@Suite struct WindowFittingPlanTests {
    /// Two windows overlapping by 120pt, neither known to be constrained.
    private var cramped: [WindowFitting.Window] {
        [
            window(1, "chrome", x: 0, width: 900, arrived: 100),
            window(2, "iterm", x: 800, width: 520, arrived: 200),
        ]
    }

    @Test func aLayoutThatFitsIsLeftAlone() {
        let roomy = [
            window(1, "chrome", x: 0, width: 600),
            window(2, "iterm", x: 700, width: 500),
        ]
        #expect(WindowFitting.nextStep(for: roomy, minimums: [:]) == .fits)
    }

    @Test func theWidestUnconstrainedWindowIsAskedFirst() {
        // Most to give, fewest passes to a fitting layout.
        let verdict = WindowFitting.nextStep(for: cramped, minimums: [:], step: 60)
        #expect(verdict == .adjusting(.shrink(id: 1, by: 60)))
    }

    @Test func aWindowAtItsFloorIsNotAskedAgain() {
        // Chrome is the widest, but we've learned it won't go below 880 — so
        // asking it for another 60 would just be refused. iTerm gets the ask.
        let verdict = WindowFitting.nextStep(
            for: cramped, minimums: ["chrome": 880], step: 60)
        #expect(verdict == .adjusting(.shrink(id: 2, by: 60)))
    }

    @Test func whenNothingCanShrinkTheNewestArrivalIsEvicted() {
        // Both are on their floor and they still overlap: no arrangement of
        // these two fits. iTerm arrived last, so iTerm leaves.
        let verdict = WindowFitting.nextStep(
            for: cramped, minimums: ["chrome": 880, "iterm": 500], step: 60)
        #expect(verdict == .adjusting(.evict(id: 2)))
    }

    @Test func overflowCanBeTurnedOffAndThenWeSaySo() {
        // Someone who disabled overflow is choosing to live with the overlap;
        // the verdict still reports it rather than pretending the layout fits.
        let verdict = WindowFitting.nextStep(
            for: cramped, minimums: ["chrome": 880, "iterm": 500], step: 60,
            overflowEnabled: false)
        #expect(verdict == .cannotFit(count: 2))
    }

    @Test func theStepIsNeverAskedForBelowAKnownFloor() {
        // Chrome could give 20pt before hitting 880, but the step is 60 — so
        // it's not a candidate. Asking would waste a pass and teach nothing.
        let verdict = WindowFitting.nextStep(
            for: cramped, minimums: ["chrome": 880, "iterm": 460], step: 60)
        #expect(verdict == .adjusting(.shrink(id: 2, by: 60)))
    }
}

/// The minimum is learned from what a window does when asked to shrink —
/// there's no API that will simply tell us.
@Suite struct MinimumLearningTests {
    @Test func aWindowThatGivesTheFullAskTeachesNothing() {
        // It had the room. Its real floor is still somewhere below.
        let learned = WindowFitting.learnedMinimum(
            bundleID: "chrome", requested: 80, before: 900, after: 820)
        #expect(learned == nil)
    }

    @Test func aWindowThatPushesBackRevealsItsFloor() {
        // Asked for 80, gave 30 and stopped — 870 is where it stops.
        let learned = WindowFitting.learnedMinimum(
            bundleID: "discord", requested: 80, before: 900, after: 870)
        #expect(learned?.bundleID == "discord")
        #expect(learned?.minimum == 870)
    }

    @Test func aWindowThatRefusesEntirelyIsAlreadyAtItsFloor() {
        let learned = WindowFitting.learnedMinimum(
            bundleID: "discord", requested: 80, before: 900, after: 900)
        #expect(learned?.minimum == 900)
    }

    @Test func aPointOfRoundingSlackIsNotPushback() {
        // Fractional frames mean an honest 80 can measure as 79.4.
        let learned = WindowFitting.learnedMinimum(
            bundleID: "chrome", requested: 80, before: 900, after: 820.4)
        #expect(learned == nil)
    }
}
