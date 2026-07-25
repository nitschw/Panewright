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
    public private(set) var widths: [String: CGFloat]
    private let file: URL

    public init(file: URL, widths: [String: CGFloat] = [:]) {
        self.file = file
        self.widths = widths
    }

    public static func `default`(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MinimumSizeStore {
        MinimumSizeStore(
            file: home.appending(path: ".config/panewright/min-sizes.json"))
    }

    public func minimum(for bundleID: String) -> CGFloat? { widths[bundleID] }

    /// Records a floor, keeping the *smallest* seen.
    ///
    /// A window can refuse to shrink for reasons that aren't its minimum — it
    /// was mid-animation, the app was busy, a sheet was up. Those look like a
    /// higher floor than the truth. Taking the smallest observation means a
    /// spurious refusal is corrected by the next honest one, instead of
    /// permanently over-reserving space for that app.
    public mutating func record(bundleID: String, minimum: CGFloat) {
        guard minimum > 0 else { return }
        if let known = widths[bundleID], known <= minimum { return }
        widths[bundleID] = minimum
    }

    /// Forget everything — for when a display or scaling change makes the
    /// learned floors meaningless.
    public mutating func reset() { widths = [:] }

    // MARK: Persistence

    public mutating func load() {
        guard let data = try? Data(contentsOf: file),
            let decoded = try? JSONDecoder().decode([String: CGFloat].self, from: data)
        else { return }
        widths = decoded
    }

    /// Best-effort: losing the cache costs a few resizes to relearn, never
    /// correctness, so a write failure must not interrupt anything.
    public func save() {
        guard let data = try? JSONEncoder().encode(widths) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
