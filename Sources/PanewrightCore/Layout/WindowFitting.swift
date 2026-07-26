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
///
/// Everything below is written against an ``Axis`` rather than against width.
/// A column of stacked windows fails exactly the way a row does — an app with
/// a minimum height draws over the window beneath it — so the two directions
/// are the same algorithm with the coordinates swapped, not two algorithms
/// that have to be kept in agreement.
public enum WindowFitting {
    /// Which direction windows are competing for space in.
    ///
    /// The projections below are the *only* place either direction is spelled
    /// out. Every rule — deficit, slack, the choice of who gives up space —
    /// reads geometry through these, so neither axis can drift from the other.
    public enum Axis: String, CaseIterable, Equatable, Sendable {
        case horizontal
        case vertical

        /// The axis windows are laid out along when they compete on this one.
        /// Two windows only contest width if they share rows, and only contest
        /// height if they share columns.
        var cross: Axis { self == .horizontal ? .vertical : .horizontal }

        func start(_ rect: CGRect) -> CGFloat { self == .horizontal ? rect.minX : rect.minY }
        func end(_ rect: CGRect) -> CGFloat { self == .horizontal ? rect.maxX : rect.maxY }
        /// Public because callers measuring a resize's effect have to measure
        /// along the same axis they asked about.
        public func extent(_ rect: CGRect) -> CGFloat {
            self == .horizontal ? rect.width : rect.height
        }

        /// The dimension keyword AeroSpace's `resize` expects.
        public var resizeDimension: String { self == .horizontal ? "width" : "height" }
    }

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
        /// Ask this window to give up space along an axis. Whatever it
        /// actually gives up teaches us its floor in that direction.
        case shrink(id: UInt32, by: Int, axis: Axis)
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

    /// Learned floors, per axis. Absent means "not known to be constrained".
    public struct Minimums: Equatable, Sendable {
        public var byAxis: [Axis: [String: CGFloat]]

        public init(byAxis: [Axis: [String: CGFloat]] = [:]) {
            self.byAxis = byAxis
        }

        public init(widths: [String: CGFloat], heights: [String: CGFloat] = [:]) {
            byAxis = [.horizontal: widths, .vertical: heights]
        }

        public func floor(_ bundleID: String, _ axis: Axis) -> CGFloat? {
            byAxis[axis]?[bundleID]
        }

        public mutating func record(_ bundleID: String, _ axis: Axis, _ value: CGFloat) {
            byAxis[axis, default: [:]][bundleID] = value
        }
    }

    /// How much space needs to be reclaimed along `axis` for the layout to work.
    ///
    /// Two failure modes, and the second is invisible to a pairwise check: a
    /// window can be pushed past the edge of the display, where it overlaps
    /// nothing at all and yet is plainly broken — part of it simply cannot be
    /// seen.
    ///
    /// Returning the *amount* rather than a yes/no matters just as much. The
    /// deficit is usually small — eleven points, not sixty — and asking for a
    /// fixed step overshoots, which makes AeroSpace redistribute space and
    /// move the problem somewhere else instead of fixing it.
    ///
    /// - Parameter separation: the gap neighbours are supposed to have between
    ///   them (the config's inner gap). Aiming merely for "not overlapping"
    ///   leaves windows touching, which still looks broken — more so than it
    ///   sounds, because the focus border is drawn *outside* the frame, so a
    ///   two-point overlap shows up as a couple of dozen points of overlapping
    ///   border.
    public static func deficit(
        in windows: [Window], bounds: CGRect?, separation: CGFloat = 0,
        axis: Axis = .horizontal, tolerance: CGFloat = 1
    ) -> CGFloat {
        var worst: CGFloat = 0
        for i in windows.indices {
            for j in windows.indices where j > i {
                let a = windows[i].frame
                let b = windows[j].frame
                // Each pair is neighbours along exactly one axis, and it's the
                // one where they're closest to being properly separated.
                //
                // Measuring the axes independently would double-count every
                // collision: two windows side by side overlapping by eleven
                // points also overlap by their entire shared height, which
                // reads as a thousand-point vertical deficit and sends the
                // corrector off resizing in the wrong direction. Taking the
                // smaller of the two is what identifies which way they're
                // meant to be laid out.
                let missingAlong = Axis.allCases.map { candidate -> (Axis, CGFloat) in
                    let leadingIsA = candidate.start(a) <= candidate.start(b)
                    let leading = leadingIsA ? a : b
                    let trailing = leadingIsA ? b : a
                    return (
                        candidate,
                        separation - (candidate.start(trailing) - candidate.end(leading))
                    )
                }
                guard let neighbouring = missingAlong.min(by: { $0.1 < $1.1 }) else { continue }
                guard neighbouring.0 == axis, neighbouring.1 > tolerance else { continue }
                worst = max(worst, neighbouring.1)
            }
        }
        if let bounds {
            for window in windows {
                let past =
                    max(0, axis.start(bounds) - axis.start(window.frame))
                    + max(0, axis.end(window.frame) - axis.end(bounds))
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
    /// Both axes are measured every pass and the worse one is addressed first,
    /// so a workspace that's broken horizontally *and* vertically converges on
    /// whichever is further out rather than favouring a direction.
    public static func nextStep(
        for windows: [Window],
        minimums: Minimums,
        bounds: CGRect? = nil,
        separation: CGFloat = 0,
        step: Int = 240,
        overflowEnabled: Bool = true
    ) -> Verdict {
        let worst = Axis.allCases
            .map { (axis: $0, need: deficit(
                in: windows, bounds: bounds, separation: separation, axis: $0)) }
            .max { $0.need < $1.need }
        guard let worst, worst.need > 0 else { return .fits }
        let need = worst.need

        // Take the space from whichever window has the most *slack* — room
        // above the floor its app will actually honor, in this direction.
        //
        // Neither of the more obvious rules works. Shrinking the largest
        // window picks one that's often already at its minimum, so it simply
        // refuses. Growing the window that's overflowing looks right, but
        // AeroSpace takes the space from all of its siblings proportionally,
        // and a sibling sitting on its own floor can't give any — so the
        // overlap relocates instead of closing.
        //
        // Slack is the metric that makes progress monotone: a window with room
        // above its floor is one we know can comply, and every point it yields
        // is redistributed to the windows that are cramped.
        //
        // It also makes the failure case exact. Slots always sum to the
        // display, so if no window has slack, the minimums genuinely exceed
        // the screen and no arrangement exists. That — and only that — is when
        // something has to leave.
        let candidates =
            windows
            .filter {
                hasNeighbour($0, among: windows, along: worst.axis, separation: separation)
            }
            .map { (window: $0, slack: slack(of: $0, minimums: minimums, axis: worst.axis)) }
            // Any usable room counts, not only enough to close the whole gap
            // alone. Requiring a single window to absorb the entire ask meant
            // three windows with fifty points of room each were all discarded
            // and something got evicted instead — the layout was fixable and
            // nothing was even asked.
            .filter { $0.slack >= Self.smallestUsefulAsk }
            .sorted { $0.slack > $1.slack }
        if let target = candidates.first {
            // Take as much as this window can actually give toward the
            // deficit. Asking for a fixed step when it has more to spare is
            // what made this crawl: a 300pt gap became five round trips
            // through AeroSpace instead of one.
            let ask = clamp(min(need, target.slack), step: step)
            return .adjusting(.shrink(id: target.window.id, by: ask, axis: worst.axis))
        }
        guard overflowEnabled, let newest = windows.max(by: { $0.arrived < $1.arrived })
        else { return .cannotFit(count: windows.count) }
        return .adjusting(.evict(id: newest.id))
    }

    /// Whether a set of windows can share a display at all, and why not.
    ///
    /// There is no API that reports a window's minimum size across processes —
    /// AX exposes the current size, not the constraint — so this can only
    /// reason about apps whose floor has already been learned by asking them
    /// to shrink. Unknown apps are counted as "no known floor", which makes
    /// this an under-estimate of the space needed: it can say a layout is
    /// impossible, never that one is fine.
    public struct Capacity: Equatable, Sendable {
        /// Space the known floors demand, gaps included.
        public let required: CGFloat
        /// Space the display has.
        public let available: CGFloat
        /// Apps whose floor is known, largest first, for the explanation.
        public let known: [(name: String, floor: CGFloat)]
        /// How many windows we know nothing about.
        public let unknown: Int

        public var fits: Bool { required <= available }

        public static func == (a: Capacity, b: Capacity) -> Bool {
            a.required == b.required && a.available == b.available
                && a.unknown == b.unknown && a.known.map(\.name) == b.known.map(\.name)
        }

        /// A sentence naming the arithmetic. "It doesn't fit" invites an
        /// argument; the numbers end it.
        public var explanation: String {
            guard !known.isEmpty else { return "" }
            let parts = known.prefix(3).map { "\($0.name) \(Int($0.floor))" }
            let tail = known.count > 3 ? " +\(known.count - 3) more" : ""
            return "needs \(Int(required))pt (\(parts.joined(separator: ", "))\(tail))"
                + " but the display is \(Int(available))pt"
        }
    }

    /// Can these windows share the display, given what we know about them?
    public static func capacity(
        of windows: [Window], minimums: Minimums, bounds: CGRect,
        separation: CGFloat, axis: Axis = .horizontal
    ) -> Capacity {
        var known: [(name: String, floor: CGFloat)] = []
        var unknown = 0
        var total: CGFloat = 0
        for window in windows {
            if let floor = minimums.floor(window.bundleID, axis) {
                known.append(
                    (window.bundleID.split(separator: ".").last.map(String.init)
                        ?? window.bundleID, floor))
                total += floor
            } else {
                unknown += 1
            }
        }
        // The gaps between them count against the display just as the windows do.
        total += separation * CGFloat(max(0, windows.count - 1))
        return Capacity(
            required: total, available: axis.extent(bounds),
            known: known.sorted { $0.floor > $1.floor }, unknown: unknown)
    }

    /// Ask for what's missing, not a fixed step. Overshooting makes AeroSpace
    /// redistribute more than the layout needed, which relocates the problem
    /// instead of solving it. Rounded up with a small margin for fractional
    /// frames, floored at something worth a round trip, capped by the step.
    private static func clamp(_ need: CGFloat, step: Int) -> Int {
        min(step, max(Int(smallestUsefulAsk), Int((need + 4).rounded(.up))))
    }

    /// Below this, a resize round trip costs more than the space it recovers.
    static let smallestUsefulAsk: CGFloat = 8

    /// Which axis two windows are neighbours along, if any.
    ///
    /// A pair competes along exactly one axis: the one where they're closest
    /// to being properly separated. This is the same judgement `deficit` makes
    /// and it has to be the same rule, because a pair that is *overlapping*
    /// shares both spans and so looks adjacent in both directions at once.
    private static func neighbourAxis(
        _ a: CGRect, _ b: CGRect, separation: CGFloat
    ) -> (axis: Axis, missing: CGFloat)? {
        Axis.allCases.map { axis -> (axis: Axis, missing: CGFloat) in
            let leadingIsA = axis.start(a) <= axis.start(b)
            let leading = leadingIsA ? a : b
            let trailing = leadingIsA ? b : a
            return (axis, separation - (axis.start(trailing) - axis.end(leading)))
        }
        .min { $0.missing < $1.missing }
    }

    /// Whether this window has anyone to trade space with along `axis`.
    ///
    /// A window alone in its column cannot give up height: there is no
    /// vertical sibling for AeroSpace to hand the space to, so the resize is a
    /// no-op. Asking anyway wastes a step, and — worse — the window's refusal
    /// to change looks exactly like hitting its minimum, which writes a
    /// fictional floor into the learned sizes.
    ///
    /// Judged through `neighbourAxis` rather than by asking whether some other
    /// window merely overlaps this one's cross-axis span. That looser test was
    /// fooled by precisely the situation this code exists for: two windows
    /// drawn on top of each other share both spans, so a side-by-side pair
    /// registered as vertical neighbours, got asked to give up height they had
    /// no way to give, and recorded floors equal to the full screen height.
    private static func hasNeighbour(
        _ window: Window, among windows: [Window], along axis: Axis, separation: CGFloat
    ) -> Bool {
        windows.contains { other in
            guard other.id != window.id else { return false }
            return neighbourAxis(window.frame, other.frame, separation: separation)?.axis == axis
        }
    }

    /// Room above the floor this app will honor along `axis`. An unknown floor
    /// counts as all of it: we've never made this app refuse, so it's the most
    /// promising thing to ask — and if it does refuse, that refusal is what
    /// teaches us its minimum.
    private static func slack(
        of window: Window, minimums: Minimums, axis: Axis
    ) -> CGFloat {
        guard let floor = minimums.floor(window.bundleID, axis) else {
            return axis.extent(window.frame)
        }
        return max(0, axis.extent(window.frame) - floor)
    }

    /// What a shrink attempt taught us.
    ///
    /// Asked for 80 and got 80: it had the room, we've learned nothing. Asked
    /// for 80 and got 30 (or nothing): it hit its floor, and that floor is the
    /// size it's sitting at now.
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
