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

/// A window shoved past the edge of the display overlaps nothing at all, and
/// is just as broken — half of it can't be seen.
@Suite struct OffScreenTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func aWindowPastTheRightEdgeCounts() {
        let windows = [
            window(1, "a", x: 0, width: 900),
            window(2, "b", x: 908, width: 900),  // runs 80pt off the right
        ]
        // Invisible to a pairwise check: these two don't touch each other.
        #expect(WindowFitting.overlaps(in: windows).isEmpty)
        #expect(WindowFitting.deficit(in: windows, bounds: screen) == 80)
    }

    @Test func aWindowPastTheLeftEdgeCounts() {
        let windows = [
            window(1, "a", x: -40, width: 600),
            window(2, "b", x: 700, width: 600),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: screen) == 40)
    }

    @Test func anOffScreenWindowIsActedOnRatherThanIgnored() {
        // The bug this closes: overlap-only detection called this layout fine
        // and never evicted anything, so a window stayed half off the display.
        let windows = [
            window(1, "a", x: 0, width: 900, arrived: 100),
            window(2, "b", x: 908, width: 900, arrived: 200),
        ]
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: [:], bounds: screen, step: 60)
        #expect(verdict != .fits)
    }

    @Test func aLayoutInsideTheScreenIsStillFine() {
        let windows = [
            window(1, "a", x: 8, width: 850),
            window(2, "b", x: 868, width: 850),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: screen) == 0)
        #expect(WindowFitting.nextStep(for: windows, minimums: [:], bounds: screen) == .fits)
    }

    @Test func withoutKnownBoundsOnlyOverlapCounts() {
        // Multi-monitor and unknown-display cases must not invent a deficit.
        let windows = [
            window(1, "a", x: 0, width: 900),
            window(2, "b", x: 908, width: 900),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: nil) == 0)
    }
}

/// The size of the ask matters as much as the choice of window: overshooting
/// makes AeroSpace redistribute more than the layout needed, which relocates
/// the problem instead of fixing it.
@Suite struct AskSizeTests {
    @Test func asksForWhatIsMissingRatherThanAFixedStep() {
        // The real case from a live workspace: an 11pt overlap. Asking for the
        // configured 60 caused a visible oscillation between three windows.
        let windows = [
            window(1, "chrome", x: 0, width: 900),
            window(2, "iterm", x: 889, width: 500),
        ]
        guard
            case .adjusting(.grow(_, let by)) = WindowFitting.nextStep(
                for: windows, minimums: [:], step: 60)
        else {
            Issue.record("expected a grow")
            return
        }
        // 11 needed, plus a little margin for fractional frames — nowhere near 60.
        #expect(by == 15)
    }

    @Test func theConfiguredStepIsACeilingNotATarget() {
        // A big deficit is still capped, so one correction can't yank a window
        // dramatically in a single jump.
        let windows = [
            window(1, "chrome", x: 0, width: 900),
            window(2, "iterm", x: 500, width: 500),
        ]
        guard
            case .adjusting(.grow(_, let by)) = WindowFitting.nextStep(
                for: windows, minimums: [:], step: 60)
        else {
            Issue.record("expected a grow")
            return
        }
        #expect(by == 60)
    }

    @Test func aTinyDeficitStillAsksForSomethingWorthTheRoundTrip() {
        let windows = [
            window(1, "chrome", x: 0, width: 900),
            window(2, "iterm", x: 897, width: 500),
        ]
        guard
            case .adjusting(.grow(_, let by)) = WindowFitting.nextStep(
                for: windows, minimums: [:], step: 60)
        else {
            Issue.record("expected a grow")
            return
        }
        #expect(by >= 8)
    }
}

/// The repair strategy. The subtle part is the direction: a window overlaps
/// because its *slot* is too small for it, so the fix is to widen that slot
/// and let AeroSpace take the width from the siblings — not to shrink some
/// unrelated window and hope the redistribution lands in the right place.
@Suite struct WindowFittingPlanTests {
    private var overlapping: [WindowFitting.Window] {
        [
            window(1, "chrome", x: 0, width: 900, arrived: 100),
            window(2, "iterm", x: 800, width: 520, arrived: 200),
        ]
    }

    /// A row too wide for the display: 900 + 900 on a 1000pt screen.
    private var tooWideForTheScreen: [WindowFitting.Window] {
        [
            window(1, "chrome", x: 0, width: 900, arrived: 100),
            window(2, "iterm", x: 905, width: 900, arrived: 200),
        ]
    }
    private let smallScreen = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    @Test func aLayoutThatFitsIsLeftAlone() {
        let roomy = [
            window(1, "chrome", x: 0, width: 600),
            window(2, "iterm", x: 700, width: 500),
        ]
        #expect(WindowFitting.nextStep(for: roomy, minimums: [:]) == .fits)
    }

    @Test func theOverflowingWindowHasItsSlotWidened() {
        // This is the case that failed live: Claude sat at its 600pt floor with
        // a slot narrower than that, drawing 45pt over iTerm. Shrinking the
        // widest window (Safari, at the far right) did nothing for the
        // collision on the left, and it gave up after eight wasted steps.
        // The left window of the pair is the one overflowing, so it grows.
        guard
            case .adjusting(.grow(let id, _)) = WindowFitting.nextStep(
                for: overlapping, minimums: [:], step: 60)
        else {
            Issue.record("expected the offender's slot to grow")
            return
        }
        #expect(id == 1)
    }

    @Test func aWindowAtItsFloorIsStillTheOneGrown() {
        // Knowing it can't shrink is exactly why growing its slot is right —
        // its minimum is the constraint the layout has to accommodate.
        guard
            case .adjusting(.grow(let id, _)) = WindowFitting.nextStep(
                for: overlapping, minimums: ["chrome": 900], step: 60)
        else {
            Issue.record("expected a grow")
            return
        }
        #expect(id == 1)
    }

    @Test func aRowTooWideForTheDisplayShrinksInstead() {
        // Growing anything here would push more of the row off the edge, so
        // this is the one case where width genuinely has to come out.
        guard
            case .adjusting(.shrink(let id, _)) = WindowFitting.nextStep(
                for: tooWideForTheScreen, minimums: [:], bounds: smallScreen, step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        // Either of the two 900s; the widest-first tie goes to the first.
        #expect(id == 1)
    }

    @Test func whenNothingCanShrinkTheNewestArrivalIsEvicted() {
        // Both on their floor, and the row still doesn't fit the display: no
        // arrangement of these two works. iTerm arrived last, so iTerm leaves.
        let verdict = WindowFitting.nextStep(
            for: tooWideForTheScreen, minimums: ["chrome": 900, "iterm": 900],
            bounds: smallScreen, step: 60)
        #expect(verdict == .adjusting(.evict(id: 2)))
    }

    @Test func overflowCanBeTurnedOffAndThenWeSaySo() {
        // Someone who disabled overflow is choosing to live with it; the
        // verdict still reports the problem rather than claiming it fits.
        let verdict = WindowFitting.nextStep(
            for: tooWideForTheScreen, minimums: ["chrome": 900, "iterm": 900],
            bounds: smallScreen, step: 60, overflowEnabled: false)
        #expect(verdict == .cannotFit(count: 2))
    }

    @Test func aWindowIsNeverAskedToShrinkBelowItsKnownFloor() {
        // chrome could give 20pt before hitting 880, but the ask is 60, so it
        // isn't a candidate — the request would just be refused.
        guard
            case .adjusting(.shrink(let id, _)) = WindowFitting.nextStep(
                for: tooWideForTheScreen, minimums: ["chrome": 880], bounds: smallScreen,
                step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(id == 2)
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
