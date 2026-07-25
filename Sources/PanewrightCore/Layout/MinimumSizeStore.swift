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

    /// Records a floor, keeping the *smallest* seen.
    ///
    /// A window can refuse to shrink for reasons that aren't its minimum — it
    /// was mid-animation, the app was busy, a sheet was up. Those look like a
    /// higher floor than the truth. Taking the smallest observation means a
    /// spurious refusal is corrected by the next honest one, instead of
    /// permanently over-reserving space for that app.
    public mutating func record(
        bundleID: String, axis: WindowFitting.Axis = .horizontal, minimum: CGFloat
    ) {
        guard minimum > 0 else { return }
        if let known = minimums.floor(bundleID, axis), known <= minimum { return }
        minimums.record(bundleID, axis, minimum)
    }

    /// Forget everything — for when a display or scaling change makes the
    /// learned floors meaningless.
    public mutating func reset() { minimums = WindowFitting.Minimums() }

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
