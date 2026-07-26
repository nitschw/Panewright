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
        #expect(WindowFitting.deficit(in: windows, bounds: nil) == 0)
    }

    @Test func aWindowRenderingOverItsNeighborIs() {
        // iTerm was given 400pt but won't go below 520, so it runs 120pt into
        // Safari's slot — the exact failure this whole file exists for.
        let windows = [
            window(1, "a", x: 0, width: 600),
            window(2, "iterm", x: 608, width: 520),
            window(3, "safari", x: 1008, width: 570),
        ]
        // iTerm runs 120pt into Safari's slot.
        #expect(WindowFitting.deficit(in: windows, bounds: nil) == 120)
    }

    @Test func aSharedEdgeIsNotOverlap() {
        // Gap division leaves fractional frames; a window touching its
        // neighbor's edge is a rounding artifact, not broken tiling.
        let windows = [
            window(1, "a", x: 0, width: 600),
            window(2, "b", x: 599, width: 500),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: nil) == 0)
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
        #expect(WindowFitting.deficit(in: windows, bounds: nil) == 0)
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
            for: windows, minimums: WindowFitting.Minimums(), bounds: screen, step: 60)
        #expect(verdict != .fits)
    }

    @Test func aLayoutInsideTheScreenIsStillFine() {
        let windows = [
            window(1, "a", x: 8, width: 850),
            window(2, "b", x: 868, width: 850),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: screen) == 0)
        #expect(WindowFitting.nextStep(for: windows, minimums: WindowFitting.Minimums(), bounds: screen) == .fits)
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
            case .adjusting(.shrink(_, let by, _)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(), step: 60)
        else {
            Issue.record("expected a shrink")
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
            case .adjusting(.shrink(_, let by, _)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(), step: 60)
        else {
            Issue.record("expected a shrink")
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
            case .adjusting(.shrink(_, let by, _)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(), step: 60)
        else {
            Issue.record("expected a shrink")
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
        #expect(WindowFitting.nextStep(for: roomy, minimums: WindowFitting.Minimums()) == .fits)
    }

    @Test func theWindowWithTheMostSlackGivesUpTheWidth() {
        // Nothing is known to be constrained yet, so the wider window is the
        // most promising thing to ask — and whatever it does teaches us.
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: overlapping, minimums: WindowFitting.Minimums(), step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(id == 1)
    }

    @Test func aWindowOnItsFloorIsNeverTheOneAsked() {
        // The live failure that forced this rule. Chrome is the widest window
        // *and* the one overlapping, but it sits exactly on its floor, so it
        // can't give up a point — asking it burns a step and changes nothing.
        // iTerm has slack, so iTerm pays, and AeroSpace hands the freed width
        // to the window that was cramped.
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: overlapping, minimums: WindowFitting.Minimums(widths: ["chrome": 900]), step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(id == 2)
    }

    @Test func theLiveThreeWindowFailureResolves() {
        // Verbatim from the workspace that beat two earlier strategies:
        // Claude and Safari both pinned on their floors with a 19pt overlap,
        // on a 1728pt display. A valid layout exists (600 + 574 + 538 + gaps
        // = 1728), and both earlier rules failed to find it — "widest" kept
        // picking a window on its floor, and growing the offender took space
        // from a sibling that had none to give.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let windows = [
            window(28087, "claude", x: 54, width: 600, arrived: 100),
            window(72236, "iterm", x: 635, width: 514, arrived: 200),
            window(93045, "safari", x: 1154, width: 574, arrived: 300),
        ]
        let minimums = WindowFitting.Minimums(widths: ["claude": 600, "safari": 574])
        // iTerm is the only one with anywhere to go, so it's the only sane ask.
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: windows, minimums: minimums, bounds: screen, separation: 5, step: 60)
        else {
            Issue.record("expected a shrink, not a stalemate")
            return
        }
        #expect(id == 72236)
    }

    @Test func nothingIsEvictedWhileAnyWindowStillHasSlack() {
        // Eviction is a last resort, and "last" has to mean it. Slots always
        // sum to the display, so as long as one window has room above its
        // floor, a fitting arrangement is still reachable by resizing.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let windows = [
            window(1, "claude", x: 54, width: 600, arrived: 100),
            window(2, "iterm", x: 635, width: 514, arrived: 200),
            window(3, "safari", x: 1154, width: 574, arrived: 300),
        ]
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: WindowFitting.Minimums(widths: ["claude": 600, "safari": 574]), bounds: screen,
            separation: 5, step: 60)
        #expect(verdict != .adjusting(.evict(id: 3)))
        #expect(verdict != .cannotFit(count: 3))
    }

    @Test func aRowTooWideForTheDisplayShrinksInstead() {
        // Growing anything here would push more of the row off the edge, so
        // this is the one case where width genuinely has to come out.
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: tooWideForTheScreen, minimums: WindowFitting.Minimums(), bounds: smallScreen, step: 60)
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
            for: tooWideForTheScreen, minimums: WindowFitting.Minimums(widths: ["chrome": 900, "iterm": 900]),
            bounds: smallScreen, step: 60)
        #expect(verdict == .adjusting(.evict(id: 2)))
    }

    @Test func overflowCanBeTurnedOffAndThenWeSaySo() {
        // Someone who disabled overflow is choosing to live with it; the
        // verdict still reports the problem rather than claiming it fits.
        let verdict = WindowFitting.nextStep(
            for: tooWideForTheScreen, minimums: WindowFitting.Minimums(widths: ["chrome": 900, "iterm": 900]),
            bounds: smallScreen, step: 60, overflowEnabled: false)
        #expect(verdict == .cannotFit(count: 2))
    }

    @Test func aWindowIsNeverAskedToShrinkBelowItsKnownFloor() {
        // chrome could give 20pt before hitting 880, but the ask is 60, so it
        // isn't a candidate — the request would just be refused.
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: tooWideForTheScreen, minimums: WindowFitting.Minimums(widths: ["chrome": 880]), bounds: smallScreen,
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

/// Vertical stacks must behave exactly as horizontal rows do — same rules,
/// same thresholds, same choice of victim — because they run the same code
/// with the coordinates swapped.
///
/// These tests assert that by *transposing*: mirror a layout across the
/// diagonal (swap x with y, width with height) and every answer must mirror
/// with it. A rule that only got implemented for one direction fails here.
@Suite struct AxisParityTests {
    /// Reflect a window across the diagonal.
    private func transposed(_ w: WindowFitting.Window) -> WindowFitting.Window {
        WindowFitting.Window(
            id: w.id, bundleID: w.bundleID,
            frame: CGRect(
                x: w.frame.minY, y: w.frame.minX,
                width: w.frame.height, height: w.frame.width),
            arrived: w.arrived)
    }

    private func transposed(_ r: CGRect) -> CGRect {
        CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
    }

    /// A row: three side-by-side windows, the middle one overlapping the last.
    private var row: [WindowFitting.Window] {
        [
            window(1, "a", x: 0, width: 600, arrived: 100),
            window(2, "b", x: 608, width: 520, arrived: 200),
            window(3, "c", x: 1108, width: 570, arrived: 300),
        ]
    }
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func theDeficitIsTheSameInEitherDirection() {
        let across = WindowFitting.deficit(
            in: row, bounds: screen, separation: 5, axis: .horizontal)
        let down = WindowFitting.deficit(
            in: row.map(transposed), bounds: transposed(screen), separation: 5,
            axis: .vertical)
        #expect(across > 0)
        #expect(across == down)
    }

    @Test func theSameWindowIsAskedInEitherDirection() {
        let across = WindowFitting.nextStep(
            for: row, minimums: WindowFitting.Minimums(widths: ["a": 600]),
            bounds: screen, separation: 5, step: 60)
        let down = WindowFitting.nextStep(
            for: row.map(transposed),
            // The mirrored layout's floors are heights, not widths.
            minimums: WindowFitting.Minimums(widths: [:], heights: ["a": 600]),
            bounds: transposed(screen), separation: 5, step: 60)

        guard case .adjusting(.shrink(let idAcross, let byAcross, let axisAcross)) = across,
            case .adjusting(.shrink(let idDown, let byDown, let axisDown)) = down
        else {
            Issue.record("both directions should ask a window to shrink")
            return
        }
        #expect(idAcross == idDown)
        #expect(byAcross == byDown)
        // Same decision, opposite direction — and the action names the axis so
        // the caller resizes width or height accordingly.
        #expect(axisAcross == .horizontal)
        #expect(axisDown == .vertical)
    }

    @Test func aWindowOnItsHeightFloorIsSkippedJustAsOnItsWidth() {
        // The slack rule has to consult the floor for the axis being fixed. A
        // stack where the tall window can't get shorter must pick the other.
        let stack = row.map(transposed)
        let minimums = WindowFitting.Minimums(widths: [:], heights: ["b": 520, "c": 570])
        guard
            case .adjusting(.shrink(let id, _, let axis)) = WindowFitting.nextStep(
                for: stack, minimums: minimums, bounds: transposed(screen),
                separation: 5, step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(axis == .vertical)
        // b and c are both on their height floors, so a is the only one left.
        #expect(id == 1)
    }

    @Test func evictionIsReachedIdenticallyInAStack() {
        let stack = row.map(transposed)
        let minimums = WindowFitting.Minimums(
            widths: [:], heights: ["a": 600, "b": 520, "c": 570])
        let verdict = WindowFitting.nextStep(
            for: stack, minimums: minimums, bounds: transposed(screen),
            separation: 5, step: 60)
        // Nothing can get shorter, so the newest arrival leaves — exactly as
        // it would in a row that can't get narrower.
        #expect(verdict == .adjusting(.evict(id: 3)))
    }

    @Test func aStackedPairIsNotJudgedOnItsHorizontalSpan() {
        // Two windows in one column share their entire width. That is not a
        // horizontal collision, and counting it as one would have the fitter
        // resizing in the direction the windows aren't even competing in.
        let a = WindowFitting.Window(
            id: 1, bundleID: "a", frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            arrived: Date())
        let b = WindowFitting.Window(
            id: 2, bundleID: "b", frame: CGRect(x: 0, y: 505, width: 800, height: 500),
            arrived: Date())
        #expect(
            WindowFitting.deficit(in: [a, b], bounds: nil, separation: 5, axis: .horizontal)
                == 0)
        #expect(
            WindowFitting.deficit(in: [a, b], bounds: nil, separation: 5, axis: .vertical)
                == 0)
    }

    @Test func aStackedPairOverlappingVerticallyIsCaught() {
        // The whole point of the exercise: an app with a minimum height drawing
        // over the window beneath it.
        let a = WindowFitting.Window(
            id: 1, bundleID: "a", frame: CGRect(x: 0, y: 0, width: 800, height: 520),
            arrived: Date())
        let b = WindowFitting.Window(
            id: 2, bundleID: "b", frame: CGRect(x: 0, y: 505, width: 800, height: 500),
            arrived: Date())
        // 15pt of overlap, plus the 5pt gap it should have had.
        #expect(
            WindowFitting.deficit(in: [a, b], bounds: nil, separation: 5, axis: .vertical)
                == 20)
    }
}

/// A window can only give up space in a direction where it has a sibling to
/// give it to. Asking otherwise doesn't just waste a step — the no-op looks
/// identical to hitting a minimum, and records a fictional floor.
@Suite struct NeighbourTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    /// Two full-height windows side by side, overlapping vertically with a
    /// third that's stacked under one of them.
    private var mixedLayout: [WindowFitting.Window] {
        [
            // Alone in its column: full height, no vertical sibling.
            WindowFitting.Window(
                id: 1, bundleID: "solo",
                frame: CGRect(x: 54, y: 36, width: 600, height: 1045),
                arrived: Date(timeIntervalSince1970: 100)),
            // A stacked pair sharing the right column, overlapping by 15pt.
            WindowFitting.Window(
                id: 2, bundleID: "top",
                frame: CGRect(x: 661, y: 36, width: 600, height: 520),
                arrived: Date(timeIntervalSince1970: 200)),
            WindowFitting.Window(
                id: 3, bundleID: "bottom",
                frame: CGRect(x: 661, y: 541, width: 600, height: 520),
                arrived: Date(timeIntervalSince1970: 300)),
        ]
    }

    @Test func aWindowAloneInItsColumnIsNeverAskedForHeight() {
        // The live bug: "learned claude won't go below 1045pt vertical" — the
        // full workspace height, recorded because a lone window in a column
        // physically cannot shrink vertically and its refusal was mistaken for
        // a minimum.
        let windows = mixedLayout
        guard
            case .adjusting(.shrink(let id, _, let axis)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(), bounds: screen,
                separation: 5, step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(axis == .vertical)
        // Only the stacked pair can trade height; the solo window must not be
        // picked however much apparent slack it has.
        #expect(id != 1)
    }

    @Test func theSoloWindowIsStillEligibleForWidth() {
        // It has horizontal neighbours, so width is fair game — the constraint
        // is per axis, not a blanket exclusion.
        let windows = [
            WindowFitting.Window(
                id: 1, bundleID: "solo",
                frame: CGRect(x: 54, y: 36, width: 700, height: 1045),
                arrived: Date(timeIntervalSince1970: 100)),
            WindowFitting.Window(
                id: 2, bundleID: "other",
                frame: CGRect(x: 700, y: 36, width: 600, height: 1045),
                arrived: Date(timeIntervalSince1970: 200)),
        ]
        guard
            case .adjusting(.shrink(let id, _, let axis)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(), bounds: screen,
                separation: 5, step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(axis == .horizontal)
        #expect(id == 1)
    }
}

/// Eviction moves a real window to another workspace, so the bar for reaching
/// it has to be high. These pin the situations that must never get there.
@Suite struct EvictionRestraintTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func aParkedOffScreenWindowWouldHaveForcedAnEviction() {
        // Not a fix in this type, but the reason the controller filters these
        // out before they ever arrive: AeroSpace parks hidden windows far off
        // the display, and a frame out there reads as a deficit no resize can
        // close. This documents the size of the phantom.
        let parked = WindowFitting.Window(
            id: 1, bundleID: "hidden",
            frame: CGRect(x: -20000, y: 36, width: 600, height: 1045),
            arrived: Date())
        let real = WindowFitting.Window(
            id: 2, bundleID: "visible",
            frame: CGRect(x: 54, y: 36, width: 600, height: 1045),
            arrived: Date())
        let need = WindowFitting.deficit(in: [parked, real], bounds: screen, separation: 5)
        // Twenty thousand points of "deficit" from a window that isn't on the
        // screen at all — unfixable by any resize, so the fitter would evict.
        #expect(need > 10000)
    }

    @Test func aWindowWithSlackIsAlwaysPreferredToEviction() {
        // Slots sum to the display, so while anything has room above its floor
        // a fitting arrangement is still reachable and nothing should be moved.
        let windows = [
            window(1, "pinned", x: 54, width: 600, arrived: 100),
            window(2, "roomy", x: 600, width: 900, arrived: 200),
        ]
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: WindowFitting.Minimums(widths: ["pinned": 600]),
            bounds: screen, separation: 5, step: 60)
        guard case .adjusting(.shrink(let id, _, _)) = verdict else {
            Issue.record("expected a shrink, not an eviction")
            return
        }
        #expect(id == 2)
    }
}

/// Side-by-side windows that are overlapping share both spans, so a naive
/// "do we share a cross-axis span?" test declares them neighbours in both
/// directions at once — which had them asked to give up height they had no way
/// to give, recording floors equal to the whole screen.
@Suite struct NeighbourAxisTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func overlappingSideBySideWindowsAreNotVerticalNeighbours() {
        // Full height, overlapping horizontally by 80pt: the classic failure.
        let a = WindowFitting.Window(
            id: 1, bundleID: "a", frame: CGRect(x: 54, y: 36, width: 600, height: 1045),
            arrived: Date(timeIntervalSince1970: 100))
        let b = WindowFitting.Window(
            id: 2, bundleID: "b", frame: CGRect(x: 574, y: 36, width: 663, height: 1045),
            arrived: Date(timeIntervalSince1970: 200))
        // The pair competes for width, never height.
        #expect(
            WindowFitting.deficit(in: [a, b], bounds: screen, separation: 5, axis: .vertical)
                == 0)
        guard
            case .adjusting(.shrink(_, _, let axis)) = WindowFitting.nextStep(
                for: [a, b], minimums: WindowFitting.Minimums(), bounds: screen,
                separation: 5, step: 60)
        else {
            Issue.record("expected a shrink")
            return
        }
        // A vertical ask here can only be refused, and that refusal would be
        // written down as a fictional full-height minimum.
        #expect(axis == .horizontal)
    }

    @Test func genuinelyStackedWindowsStillCompeteVertically() {
        // The guard must not overcorrect into ignoring real vertical layouts.
        let top = WindowFitting.Window(
            id: 1, bundleID: "a", frame: CGRect(x: 54, y: 36, width: 600, height: 540),
            arrived: Date())
        let bottom = WindowFitting.Window(
            id: 2, bundleID: "b", frame: CGRect(x: 54, y: 561, width: 600, height: 520),
            arrived: Date())
        #expect(
            WindowFitting.deficit(in: [top, bottom], bounds: screen, separation: 5,
                axis: .vertical) > 0)
    }
}

/// A window filling the display isn't sharing it, so it isn't tiling. The
/// controller drops these before measuring; this documents what happens if one
/// ever reaches the algorithm, which is why it must not.
@Suite struct FullscreenWindowTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func aFullscreenWindowWouldLookLikeAnUnfixableCollision() {
        let fullscreen = WindowFitting.Window(
            id: 1, bundleID: "iterm",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            arrived: Date(timeIntervalSince1970: 100))
        let tiled = WindowFitting.Window(
            id: 2, bundleID: "safari",
            frame: CGRect(x: 54, y: 36, width: 600, height: 1045),
            arrived: Date(timeIntervalSince1970: 200))
        // It overlaps its neighbour completely, and no resize closes that —
        // which is how full-screening an app got it evicted to the next
        // workspace. Hence the geometric filter in the controller.
        //
        // Checked across both axes: a pair is attributed to the axis they're
        // closest to being separated on, and for a window swallowing another
        // entirely that can be either one.
        let worst = WindowFitting.Axis.allCases.map {
            WindowFitting.deficit(
                in: [fullscreen, tiled], bounds: screen, separation: 5, axis: $0)
        }.max() ?? 0
        #expect(worst > 0)
    }

    @Test func theWindowsBeneathStillTileNormallyOnceItIsExcluded() {
        // With the fullscreen window filtered out, what remains is an ordinary
        // layout and must be judged as one.
        let a = WindowFitting.Window(
            id: 2, bundleID: "safari",
            frame: CGRect(x: 54, y: 36, width: 600, height: 1045), arrived: Date())
        let b = WindowFitting.Window(
            id: 3, bundleID: "claude",
            frame: CGRect(x: 659, y: 36, width: 600, height: 1045), arrived: Date())
        #expect(
            WindowFitting.nextStep(
                for: [a, b], minimums: WindowFitting.Minimums(), bounds: screen,
                separation: 5) == .fits)
    }
}

/// Reported: sending a third window to a workspace evicted one of the two
/// already there without resizing anything first.
@Suite struct PartialSlackTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func windowsWithSomeRoomAreAskedBeforeAnythingIsEvicted() {
        // Three windows, each with 30pt above its floor: 90pt collectively,
        // more than enough. None can absorb a 60pt step alone, and requiring
        // that of a single window discarded all three and evicted instead —
        // the layout was fixable and nothing was even asked.
        let windows = [
            window(1, "a", x: 0, width: 600, arrived: 100),
            window(2, "b", x: 590, width: 600, arrived: 200),
            window(3, "c", x: 1180, width: 600, arrived: 300),
        ]
        let minimums = WindowFitting.Minimums(widths: ["a": 570, "b": 570, "c": 570])
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: minimums, bounds: screen, separation: 5, step: 240)
        guard case .adjusting(.shrink) = verdict else {
            Issue.record("expected a shrink, got \(verdict)")
            return
        }
    }

    @Test func aWindowIsAskedForWhatItCanActuallyGive() {
        // Asking a fixed step when it has more to spare is what made this
        // crawl: a large gap became several round trips instead of one.
        let windows = [
            window(1, "roomy", x: 0, width: 1200, arrived: 100),
            window(2, "pinned", x: 900, width: 600, arrived: 200),
        ]
        guard
            case .adjusting(.shrink(_, let by, _)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(widths: ["pinned": 600]),
                bounds: screen, separation: 5, step: 240)
        else {
            Issue.record("expected a shrink")
            return
        }
        // The overlap is 300pt; one ask should close most of it, not 60pt of it.
        #expect(by > 60)
    }

    @Test func evictionStillHappensWhenNothingHasAnyRoom() {
        // The rule only relaxes who counts as a candidate — a layout where
        // every window is genuinely on its floor still can't be resized.
        let windows = [
            window(1, "a", x: 0, width: 900, arrived: 100),
            window(2, "b", x: 890, width: 900, arrived: 200),
        ]
        let minimums = WindowFitting.Minimums(widths: ["a": 900, "b": 900])
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: minimums, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            separation: 5, step: 240)
        #expect(verdict == .adjusting(.evict(id: 2)))
    }
}

/// There's no cross-process API for a window's minimum size — AX reports the
/// current size, not the constraint — so this reasons only about apps whose
/// floor has been learned by asking them to shrink.
@Suite struct CapacityTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func theRealCaseIsCorrectlyCalledImpossible() {
        // Measured on a live machine: Discord genuinely stops at 800pt wide.
        // 800 + 600 + 574 + gaps is more than 1728, so no arrangement works
        // and the eviction was right.
        let windows = [
            window(1, "com.hnc.Discord", x: 0, width: 800),
            window(2, "com.anthropic.claudefordesktop", x: 810, width: 600),
            window(3, "com.apple.Safari", x: 1420, width: 574),
        ]
        let minimums = WindowFitting.Minimums(widths: [
            "com.hnc.Discord": 800, "com.anthropic.claudefordesktop": 600,
            "com.apple.Safari": 574,
        ])
        let capacity = WindowFitting.capacity(
            of: windows, minimums: minimums, bounds: screen, separation: 5)
        #expect(!capacity.fits)
        #expect(capacity.required == 1984)  // 1974 + two 5pt gaps
        // The message has to carry the numbers: "it doesn't fit" invites an
        // argument, the arithmetic ends it.
        #expect(capacity.explanation.contains("Discord 800"))
        #expect(capacity.explanation.contains("1728"))
    }

    @Test func aRoomyLayoutIsNotCalledImpossible() {
        let windows = [
            window(1, "com.apple.Safari", x: 0, width: 574),
            window(2, "com.googlecode.iterm2", x: 600, width: 412),
        ]
        let minimums = WindowFitting.Minimums(widths: [
            "com.apple.Safari": 574, "com.googlecode.iterm2": 412,
        ])
        #expect(
            WindowFitting.capacity(
                of: windows, minimums: minimums, bounds: screen, separation: 5).fits)
    }

    @Test func unknownAppsMakeThisAnUnderEstimate() {
        // An app we've never made refuse contributes nothing to the total, so
        // this can say a layout is impossible but never that one is fine.
        let windows = [
            window(1, "com.hnc.Discord", x: 0, width: 800),
            window(2, "com.example.unmeasured", x: 810, width: 600),
        ]
        let capacity = WindowFitting.capacity(
            of: windows, minimums: WindowFitting.Minimums(widths: ["com.hnc.Discord": 800]),
            bounds: screen, separation: 5)
        #expect(capacity.unknown == 1)
        #expect(capacity.required == 805)  // only the known floor plus the gap
        #expect(capacity.fits)
    }

    @Test func theBiggestOffenderIsNamedFirst() {
        let windows = [
            window(1, "com.apple.Safari", x: 0, width: 574),
            window(2, "com.hnc.Discord", x: 600, width: 800),
        ]
        let capacity = WindowFitting.capacity(
            of: windows,
            minimums: WindowFitting.Minimums(widths: [
                "com.apple.Safari": 574, "com.hnc.Discord": 800,
            ]),
            bounds: screen, separation: 5)
        #expect(capacity.known.first?.name == "Discord")
    }
}

/// A window can sit inside the screen and outside the region AeroSpace tiles
/// into — below the workspace but above the bottom of the display. Judged
/// against the screen it looks fine; judged against the tiled area it's the
/// "partially outside the tiles" a vertical resize leaves behind.
@Suite struct TiledAreaBoundsTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    /// Outer gap 8, plus 40 reserved for the bar at the bottom.
    private let tiled = CGRect(x: 8, y: 8, width: 1712, height: 1069)

    @Test func aWindowBelowTheTiledAreaIsNoticed() {
        let windows = [
            window(1, "a", x: 8, width: 800),
            WindowFitting.Window(
                id: 2, bundleID: "b",
                // Ends at 1100: inside the 1117 screen, past the 1077 tiled area.
                frame: CGRect(x: 820, y: 600, width: 800, height: 500),
                arrived: Date()),
        ]
        #expect(
            WindowFitting.deficit(in: windows, bounds: screen, axis: .vertical) == 0,
            "the screen calls this fine, which is the bug")
        #expect(WindowFitting.deficit(in: windows, bounds: tiled, axis: .vertical) > 0)
    }

    @Test func aWindowInsideTheTiledAreaIsStillFine() {
        let windows = [
            WindowFitting.Window(
                id: 1, bundleID: "a", frame: CGRect(x: 8, y: 8, width: 800, height: 1069),
                arrived: Date()),
            WindowFitting.Window(
                id: 2, bundleID: "b", frame: CGRect(x: 816, y: 8, width: 800, height: 1069),
                arrived: Date()),
        ]
        #expect(WindowFitting.deficit(in: windows, bounds: tiled, axis: .vertical) == 0)
    }
}

/// An app's technical minimum is not a size worth having.
@Suite struct UsableMinimumTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func aWindowIsNotCrushedBelowSomethingUsable() {
        // The reported case: iTerm accepts 87pt wide, so it always had "room"
        // and was shrunk a little more with every window added, while eviction
        // was never reached because something always looked shrinkable.
        let windows = [
            window(1, "claude", x: 52, width: 600, arrived: 100),
            window(2, "safari", x: 559, width: 574, arrived: 200),
            window(3, "discord", x: 1063, width: 800, arrived: 300),
            window(4, "iterm", x: 1568, width: 156, arrived: 400),
        ]
        let minimums = WindowFitting.Minimums(widths: [
            "claude": 600, "safari": 574, "discord": 800, "iterm": 87,
        ])
        // With no usable floor, the terminal keeps being the victim.
        guard
            case .adjusting(.shrink(let victim, _, _)) = WindowFitting.nextStep(
                for: windows, minimums: minimums, bounds: screen, separation: 5, usable: 0)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(victim == 4)

        // With one, nothing has usable room and the workspace is admitted full.
        let verdict = WindowFitting.nextStep(
            for: windows, minimums: minimums, bounds: screen, separation: 5, usable: 360)
        #expect(verdict == .adjusting(.evict(id: 4)))
    }

    @Test func aWindowWellAboveTheUsableFloorStillGivesSpace() {
        // The floor only stops the crushing; it mustn't stop ordinary fitting.
        let windows = [
            window(1, "roomy", x: 0, width: 1200, arrived: 100),
            window(2, "pinned", x: 1100, width: 600, arrived: 200),
        ]
        guard
            case .adjusting(.shrink(let id, _, _)) = WindowFitting.nextStep(
                for: windows, minimums: WindowFitting.Minimums(widths: ["pinned": 600]),
                bounds: screen, separation: 5, usable: 360)
        else {
            Issue.record("expected a shrink")
            return
        }
        #expect(id == 1)
    }
}
