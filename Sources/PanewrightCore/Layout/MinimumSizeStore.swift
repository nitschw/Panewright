import CoreGraphics
import Foundation

/// Remembers how small each app will actually go.
///
/// There is no API that reports a window's minimum size, so the only way to
/// know is to ask it to shrink and watch it refuse. That's an expensive way to
/// learn something — it costs a visible resize — so it's learned once per app
/// and kept. An app's floor doesn't change between launches.
///
/// Keyed by bundle ID rather than window id: the constraint belongs to the
/// app, and applying it to the next window it opens is the whole point.
public struct MinimumSizeStore: Sendable {
    /// Floors per axis. Stacked windows hit minimum *heights* exactly the way
    /// a row hits minimum widths, and an app's two floors are unrelated
    /// numbers, so they're learned and kept separately.
    public private(set) var minimums: WindowFitting.Minimums
    private let file: URL

    /// The horizontal floors, which is all there was before heights existed.
    public var widths: [String: CGFloat] { minimums.byAxis[.horizontal] ?? [:] }
    public var heights: [String: CGFloat] { minimums.byAxis[.vertical] ?? [:] }

    public init(file: URL, widths: [String: CGFloat] = [:], heights: [String: CGFloat] = [:]) {
        self.file = file
        self.minimums = WindowFitting.Minimums(widths: widths, heights: heights)
    }

    public static func `default`(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MinimumSizeStore {
        MinimumSizeStore(
            file: home.appending(path: ".config/panewright/min-sizes.json"))
    }

    public func minimum(
        for bundleID: String, axis: WindowFitting.Axis = .horizontal
    ) -> CGFloat? {
        minimums.floor(bundleID, axis)
    }

    /// Records a refusal: the app declined to go below this, so this is the
    /// floor as of now.
    ///
    /// Deliberately *not* "keep the smallest ever seen", which is what this
    /// used to do. An app's minimum is not a constant — Safari's changes with
    /// its sidebar and content, and was measured at 574 one hour and 753 the
    /// next. Keeping the smallest meant every fresh, correct measurement was
    /// thrown away in favour of a stale optimistic one, so the fitter believed
    /// a window could shrink further than it could: it asked, was refused,
    /// asked again, and burned its whole attempt budget instead of concluding
    /// the windows genuinely don't fit. An optimistic floor doesn't just waste
    /// effort — it hides the case where something needs to be evicted.
    ///
    /// The risk of trusting the latest refusal is that a window can decline
    /// for reasons that aren't its minimum (mid-animation, app busy), which
    /// records a floor that's too high. `observe` is the correction for that.
    public mutating func record(
        bundleID: String, axis: WindowFitting.Axis = .horizontal, minimum: CGFloat
    ) {
        guard minimum > 0 else { return }
        minimums.record(bundleID, axis, minimum)
    }

    /// Records a size the window was actually seen at.
    ///
    /// Proof, not inference: if a window is sitting at 600 points wide then its
    /// minimum cannot be more than 600, whatever we previously recorded. This
    /// is what lets a floor come back down after a spurious refusal inflated
    /// it, without which `record` would ratchet upward forever.
    public mutating func observe(
        bundleID: String, axis: WindowFitting.Axis, size: CGFloat
    ) {
        guard size > 0, let known = minimums.floor(bundleID, axis), known > size else { return }
        minimums.record(bundleID, axis, size)
    }

    /// Forget everything — for when a display or scaling change makes the
    /// learned floors meaningless.
    public mutating func reset() { minimums = WindowFitting.Minimums() }

    /// Discard floors too close to the size of the display itself.
    ///
    /// No real app has a minimum width of nearly the whole screen. A number
    /// that large is the signature of a resize that did nothing — a window
    /// with no sibling to trade with can't change size, and that no-op is
    /// indistinguishable from an app refusing at its floor. Such a value is
    /// worse than having none: the app reads as permanently unshrinkable, so
    /// the fitter skips it and concludes the layout is impossible, which sends
    /// it looking for something to evict.
    ///
    /// Applied on load as well as on write, so a file already poisoned by an
    /// earlier build heals itself instead of needing to be deleted by hand.
    public mutating func discardImplausible(displayWidth: CGFloat, displayHeight: CGFloat) {
        let limits: [WindowFitting.Axis: CGFloat] = [
            .horizontal: displayWidth * 0.8, .vertical: displayHeight * 0.8,
        ]
        for (axis, limit) in limits {
            guard var floors = minimums.byAxis[axis] else { continue }
            floors = floors.filter { $0.value <= limit }
            minimums.byAxis[axis] = floors
        }
    }

    // MARK: Persistence

    /// On disk as `{"widths": {...}, "heights": {...}}`.
    private struct Stored: Codable {
        var widths: [String: CGFloat]
        var heights: [String: CGFloat]
    }

    public mutating func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        if let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            minimums = WindowFitting.Minimums(
                widths: decoded.widths, heights: decoded.heights)
            return
        }
        // Files written before heights existed are a flat map of widths.
        // Reading them keeps hard-won measurements rather than making every
        // app get shrunk again to relearn what we already knew.
        if let flat = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            minimums = WindowFitting.Minimums(widths: flat)
        }
    }

    /// Best-effort: losing the cache costs a few resizes to relearn, never
    /// correctness, so a write failure must not interrupt anything.
    public func save() {
        let stored = Stored(widths: widths, heights: heights)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
