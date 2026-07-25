import Foundation

/// Other software that moves windows.
///
/// Two tiling engines on one desktop is not a degraded experience, it's an
/// unusable one: both watch the same windows, each treats the other's moves as
/// something to correct, and they take turns undoing each other. Panewright's
/// window fitting makes it worse — it reads the other tool's placement as a
/// broken layout and resizes to "fix" it, forever.
///
/// So a dedicated window manager blocks startup rather than producing a
/// warning nobody reads. That's a strong thing to do to someone's launch, and
/// it's why the list is deliberately narrow.
public enum CompetingWindowManagers {
    public struct Tool: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        /// GUI apps are matched on bundle ID — stabler than a process name,
        /// which changes with the executable.
        public let bundleID: String?
        /// Command-line daemons have no bundle ID.
        public let processName: String?
        /// What it does to us, in the message the user actually reads.
        public let note: String

        public init(name: String, bundleID: String? = nil, processName: String? = nil, note: String) {
            self.name = name
            self.bundleID = bundleID
            self.processName = processName
            self.note = note
        }
    }

    /// Tools that tile or place windows automatically.
    ///
    /// Only dedicated window managers are here. Launchers and automation tools
    /// (Raycast, Alfred, Hammerspoon, BetterTouchTool) can move windows too,
    /// but they do it when asked rather than continuously, and blocking on
    /// them would refuse to start for most people who have done nothing wrong.
    /// The cost of a false positive here is the app not running at all.
    ///
    /// AeroSpace is deliberately absent: Panewright supervises it, so finding
    /// it running is the expected state, not a conflict.
    public static let known: [Tool] = [
        Tool(
            name: "yabai", processName: "yabai",
            note: "a tiling window manager — it and Panewright will fight over every window"),
        Tool(
            name: "Amethyst", bundleID: "com.amethyst.Amethyst",
            note: "a tiling window manager — it and Panewright will fight over every window"),
        Tool(
            name: "Rectangle", bundleID: "com.knollsoft.Rectangle",
            note: "snaps and repositions windows, which will undo Panewright's layout"),
        Tool(
            name: "Rectangle Pro", bundleID: "com.knollsoft.Hookshot",
            note: "snaps and repositions windows, which will undo Panewright's layout"),
        Tool(
            name: "Magnet", bundleID: "com.crowdcafe.windowmagnet",
            note: "snaps windows to regions, which will undo Panewright's layout"),
        Tool(
            name: "Moom", bundleID: "com.manytricks.Moom",
            note: "moves and resizes windows automatically"),
        Tool(
            name: "Spectacle", bundleID: "com.divisiblebyzero.Spectacle",
            note: "moves and resizes windows automatically"),
        Tool(
            name: "Divvy", bundleID: "com.mizage.Divvy",
            note: "moves and resizes windows automatically"),
        Tool(
            name: "BetterSnapTool", bundleID: "com.hegenberg.BetterSnapTool",
            note: "snaps windows to regions, which will undo Panewright's layout"),
        Tool(
            name: "Loop", bundleID: "com.MrKai77.Loop",
            note: "snaps and resizes windows, which will undo Panewright's layout"),
        Tool(
            name: "Tiles", bundleID: "com.freedom.Tiles",
            note: "a tiling window manager — it and Panewright will fight over every window"),
    ]

    /// Which of the known tools are currently running.
    ///
    /// Running, not merely installed. Someone can have Rectangle sitting in
    /// /Applications unused for a year, and refusing to launch over a file on
    /// disk would be obnoxious.
    public static func running(
        bundleIDs: Set<String>, processNames: Set<String>, in catalog: [Tool] = known
    ) -> [Tool] {
        catalog.filter { tool in
            if let bundleID = tool.bundleID, bundleIDs.contains(bundleID) { return true }
            if let process = tool.processName, processNames.contains(process) { return true }
            return false
        }
    }

    /// The sentence shown when startup is held back.
    public static func explanation(for tools: [Tool]) -> String {
        guard let first = tools.first else { return "" }
        if tools.count == 1 {
            return "\(first.name) is running — \(first.note). "
                + "Quit it, then choose Restart Environment."
        }
        let names = tools.map(\.name).joined(separator: ", ")
        return "\(names) are running, and each moves windows on its own. "
            + "Quit them, then choose Restart Environment."
    }
}
