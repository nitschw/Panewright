import CoreGraphics
import Foundation

/// Decides what to do when tiled windows overlap.
///
/// Overlap happens because macOS apps have minimum sizes and AeroSpace has no
/// concept of one: it divides the workspace evenly, the app refuses to shrink
/// past its floor, and it renders over its neighbor. Nothing is logged and
/// nothing errors — the tiling just quietly stops being tiling.
///
/// Two platform facts shape everything here:
///
/// 1. AeroSpace exposes no geometry at all (`list-windows` has no rect field),
///    so the intended layout is unknowable. Actual overlap, read from
///    CGWindowList, is the only ground truth — which is fine, because it's
///    exact rather than predicted.
/// 2. `resize --window-id X width -80` does not move 80 points to a chosen
///    neighbor; AeroSpace redistributes freed space among siblings on its own
///    terms. So this cannot compute a target layout and set it. It nudges,
///    observes, and nudges again.
///
/// The second fact is also the gift: ask a window to shrink by 80, watch it
/// shrink by 30, and you've learned its minimum without probing for it.
public enum WindowFitting {
    /// A tiled window as actually rendered, not as intended.
    public struct Window: Equatable, Sendable, Identifiable {
        public let id: UInt32
        /// Keys the learned minimum — the floor belongs to the app, not to
        /// this particular window, and it's the same next launch.
        public let bundleID: String
        public let frame: CGRect
        /// When this window first appeared on the workspace. "Newest" is the
        /// one evicted when nothing fits: the window that just broke the
        /// layout is the one that leaves, so cause and effect stay adjacent.
        public let arrived: Date

        public init(id: UInt32, bundleID: String, frame: CGRect, arrived: Date) {
            self.id = id
            self.bundleID = bundleID
            self.frame = frame
            self.arrived = arrived
        }
    }

    public enum Action: Equatable, Sendable {
        /// The layout is fine, or nothing can be done about it.
        case settle
        /// Widen this window's slot, taking the space from its siblings.
        ///
        /// This is the primary repair, and the non-obvious one. A window
        /// overlaps its neighbour because its *slot* is narrower than the
        /// window will go — the app refused to shrink and drew over the top.
        /// Shrinking some other window and hoping AeroSpace's redistribution
        /// happens to reach the right place is indirect and usually doesn't;
        /// growing the offender's slot to match the space it already occupies
        /// takes the width from its siblings exactly where it's needed.
        case grow(id: UInt32, by: Int)
        /// Ask this window to give up width. Whatever it actually gives up
        /// teaches us its floor. Used when the row is too wide for the
        /// display, where growing anything would only make it worse.
        case shrink(id: UInt32, by: Int)
        /// Every window is already at its minimum and they still don't fit.
        case evict(id: UInt32)
    }

    /// Why we settled — so the caller can say something useful instead of
    /// silently giving up.
    public enum Verdict: Equatable, Sendable {
        case fits
        case adjusting(Action)
        /// Nothing fits and overflow is switched off, so the user is looking
        /// at overlapping windows on purpose.
        case cannotFit(count: Int)
    }

    /// Pairs of windows overlapping by more than `tolerance` points.
    ///
    /// The tolerance is not fussiness: window frames land on fractional points
    /// after gap division, and a shared one-point edge is not a broken layout.
    public static func overlaps(
        in windows: [Window], tolerance: CGFloat = 2
    ) -> [(UInt32, UInt32)] {
        var found: [(UInt32, UInt32)] = []
        for i in windows.indices {
            for j in windows.indices where j > i {
                let shared = windows[i].frame.intersection(windows[j].frame)
                guard !shared.isNull, shared.width > tolerance, shared.height > tolerance
                else { continue }
                found.append((windows[i].id, windows[j].id))
            }
        }
        return found
    }

    /// How many points of width need to be reclaimed for the layout to work.
    ///
    /// Two failure modes, and the second is invisible to `overlaps` alone: a
    /// window can be pushed past the edge of the display, where it overlaps
    /// nothing at all and yet is plainly broken — part of it simply cannot be
    /// seen. Checking only window-against-window declares that layout fine.
    ///
    /// Returning the *amount* rather than a yes/no matters just as much. The
    /// deficit is usually small — eleven points, not sixty — and asking for a
    /// fixed step overshoots, which makes AeroSpace redistribute space and
    /// move the problem somewhere else instead of fixing it.
    /// - Parameter separation: the gap neighbours are supposed to have between
    ///   them (the config's inner gap). Aiming merely for "not overlapping"
    ///   leaves windows touching, which still looks broken — more so than it
    ///   sounds, because the focus border is drawn *outside* the frame, so a
    ///   two-point window overlap shows up as a couple of dozen points of
    ///   overlapping border.
    public static func deficit(
        in windows: [Window], bounds: CGRect?, separation: CGFloat = 0,
        tolerance: CGFloat = 1
    ) -> CGFloat {
        var worst: CGFloat = 0
        for i in windows.indices {
            for j in windows.indices where j > i {
                let a = windows[i].frame
                let b = windows[j].frame
                // Only side-by-side windows compete for width. Stacked ones
                // share a column and their horizontal spacing is irrelevant.
                let sharedRows = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                guard sharedRows > tolerance else { continue }
                let left = a.minX <= b.minX ? a : b
                let right = a.minX <= b.minX ? b : a
                let gap = right.minX - left.maxX
                let missing = separation - gap
                if missing > tolerance { worst = max(worst, missing) }
            }
        }
        if let bounds {
            for window in windows {
                let past =
                    max(0, bounds.minX - window.frame.minX)
                    + max(0, window.frame.maxX - bounds.maxX)
                if past > tolerance { worst = max(worst, past) }
            }
        }
        return worst
    }

    /// The next single step toward a layout that fits.
    ///
    /// One step at a time on purpose: since AeroSpace redistributes space its
    /// own way, a batch of resizes computed against the current frames would
    /// be stale by the second command. Apply one, look again.
    ///
    /// - Parameters:
    ///   - minimums: learned floors by bundle ID, in points. Absent means
    ///     "not known to be constrained" — worth asking.
    ///   - step: how much width to ask for per attempt.
    ///   - overflowEnabled: whether evicting to another workspace is allowed.
    public static func nextStep(
        for windows: [Window],
        minimums: [String: CGFloat],
        bounds: CGRect? = nil,
        separation: CGFloat = 0,
        step: Int = 60,
        overflowEnabled: Bool = true
    ) -> Verdict {
        // A row wider than the display can't be repaired by moving width
        // around, so that's checked first — growing anything here would only
        // push more of it off the edge.
        if let past = pastBounds(windows, bounds), past > 0 {
            let ask = clamp(past, step: step)
            let shrinkable =
                windows
                .filter { hasRoomToShrink($0, minimums: minimums, by: ask) }
                .sorted { $0.frame.width > $1.frame.width }
            if let target = shrinkable.first {
                return .adjusting(.shrink(id: target.id, by: ask))
            }
            guard overflowEnabled, let newest = windows.max(by: { $0.arrived < $1.arrived })
            else { return .cannotFit(count: windows.count) }
            return .adjusting(.evict(id: newest.id))
        }
        // Otherwise the row fits on screen and the problem is local: some
        // window is drawn over its neighbour because its slot is too small.
        guard let (offender, missing) = worstCollision(in: windows, separation: separation)
        else { return .fits }
        return .adjusting(.grow(id: offender, by: clamp(missing, step: step)))
    }

    /// Ask for what's missing, not a fixed step. Overshooting makes AeroSpace
    /// redistribute more than the layout needed, which relocates the problem
    /// instead of solving it. Rounded up with a small margin for fractional
    /// frames, floored at something worth a round trip, capped by the step.
    private static func clamp(_ need: CGFloat, step: Int) -> Int {
        min(step, max(8, Int((need + 4).rounded(.up))))
    }

    /// The window whose slot is too narrow, and by how much.
    ///
    /// In an overlapping pair the *left* window is the one overflowing: its
    /// drawn right edge has run past where its neighbour's slot begins.
    private static func worstCollision(
        in windows: [Window], separation: CGFloat, tolerance: CGFloat = 1
    ) -> (id: UInt32, missing: CGFloat)? {
        var worst: (id: UInt32, missing: CGFloat)?
        for i in windows.indices {
            for j in windows.indices where j > i {
                let a = windows[i].frame
                let b = windows[j].frame
                guard min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance else { continue }
                let leftIsA = a.minX <= b.minX
                let left = leftIsA ? a : b
                let right = leftIsA ? b : a
                let missing = separation - (right.minX - left.maxX)
                guard missing > tolerance else { continue }
                if worst == nil || missing > worst!.missing {
                    worst = (leftIsA ? windows[i].id : windows[j].id, missing)
                }
            }
        }
        return worst
    }

    /// How far the row spills past the display, if at all.
    private static func pastBounds(
        _ windows: [Window], _ bounds: CGRect?, tolerance: CGFloat = 1
    ) -> CGFloat? {
        guard let bounds else { return nil }
        var worst: CGFloat = 0
        for window in windows {
            let past =
                max(0, bounds.minX - window.frame.minX)
                + max(0, window.frame.maxX - bounds.maxX)
            if past > tolerance { worst = max(worst, past) }
        }
        return worst
    }

    /// A window is worth asking only if it isn't already at (or under) its
    /// known floor. The amount is included so we never ask for a shrink that
    /// would land below the minimum and get refused anyway.
    private static func hasRoomToShrink(
        _ window: Window, minimums: [String: CGFloat], by amount: Int
    ) -> Bool {
        guard let floor = minimums[window.bundleID] else { return true }
        return window.frame.width - CGFloat(amount) >= floor
    }

    /// What a shrink attempt taught us.
    ///
    /// Asked for 80 and got 80: it had the room, we've learned nothing. Asked
    /// for 80 and got 30 (or nothing): it hit its floor, and that floor is the
    /// width it's sitting at now.
    public static func learnedMinimum(
        bundleID: String, requested: Int, before: CGFloat, after: CGFloat
    ) -> (bundleID: String, minimum: CGFloat)? {
        let given = before - after
        // A point of slack for fractional frames; anything less than the full
        // ask means it pushed back.
        guard given < CGFloat(requested) - 1 else { return nil }
        return (bundleID, after)
    }
}
