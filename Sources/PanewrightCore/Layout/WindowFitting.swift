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
        /// Ask this window to give up width. Whatever it actually gives up
        /// teaches us its floor.
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
        step: Int = 60,
        overflowEnabled: Bool = true
    ) -> Verdict {
        guard !overlaps(in: windows).isEmpty else { return .fits }
        // Widest first: it has the most to give, and moving the biggest lever
        // reaches a fitting layout in the fewest passes.
        let shrinkable =
            windows
            .filter { hasRoomToShrink($0, minimums: minimums, step: step) }
            .sorted { $0.frame.width > $1.frame.width }
        if let target = shrinkable.first {
            return .adjusting(.shrink(id: target.id, by: step))
        }
        // Everything is on its floor. No arrangement of these windows fits.
        guard overflowEnabled, let newest = windows.max(by: { $0.arrived < $1.arrived }) else {
            return .cannotFit(count: windows.count)
        }
        return .adjusting(.evict(id: newest.id))
    }

    /// A window is worth asking only if it isn't already at (or under) its
    /// known floor. The step is included so we never ask for a shrink that
    /// would land below the minimum and get refused anyway.
    private static func hasRoomToShrink(
        _ window: Window, minimums: [String: CGFloat], step: Int
    ) -> Bool {
        guard let floor = minimums[window.bundleID] else { return true }
        return window.frame.width - CGFloat(step) >= floor
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
