import Foundation

/// Where to send you when you switch to an app.
///
/// Cmd+Tab activates an application; it knows nothing about workspaces or
/// about windows Panewright has parked in the bar. So switching to an app
/// whose window is parked used to raise the app with nothing on screen — the
/// window is off on the hidden pills workspace — and switching to one living
/// on another workspace left you looking at the wrong workspace entirely.
///
/// The fix isn't to replace Cmd+Tab. macOS's switcher is fine, and
/// intercepting it would mean reimplementing the whole thing. It's to make
/// *activation* mean something sensible, which then works for the Dock,
/// Spotlight, Raycast and anything else that raises an app.
public enum AppSwitchRouting {
    /// A window as AeroSpace sees it, for routing purposes.
    public struct Window: Equatable, Sendable {
        public let id: UInt32
        public let bundleID: String
        public let workspace: String

        public init(id: UInt32, bundleID: String, workspace: String) {
            self.id = id
            self.bundleID = bundleID
            self.workspace = workspace
        }
    }

    public enum Action: Equatable, Sendable {
        /// Already visible where you are — macOS raising the app is enough.
        case nothing
        /// Parked in the bar: summon it out rather than leaving you staring at
        /// a workspace that doesn't contain it.
        case summonPill(id: UInt32)
        /// Living on another workspace: go there.
        case focusWindow(id: UInt32)
    }

    /// The workspace parked windows are stashed on. A letter, because
    /// workspace names in the bar are numbers.
    public static let pillsWorkspace = "P"

    /// Decide what switching to `bundleID` should do.
    ///
    /// - Parameters:
    ///   - windows: every window AeroSpace knows about.
    ///   - focusedWorkspace: the workspace on screen right now.
    public static func route(
        to bundleID: String, windows: [Window], focusedWorkspace: String
    ) -> Action {
        let mine = windows.filter { $0.bundleID == bundleID }
        guard !mine.isEmpty else { return .nothing }

        // Already here and visible: macOS has done the job.
        if mine.contains(where: { $0.workspace == focusedWorkspace }) { return .nothing }

        // Parked takes priority over a copy on another workspace. Someone who
        // parked a window in the bar chose to keep it to hand, so summoning it
        // is closer to what they meant than jumping the desktop somewhere else.
        if let parked = mine.first(where: { $0.workspace == pillsWorkspace }) {
            return .summonPill(id: parked.id)
        }

        // Elsewhere: go to it. First match, so the choice is stable rather
        // than depending on however the list came back.
        if let elsewhere = mine.first(where: { $0.workspace != focusedWorkspace }) {
            return .focusWindow(id: elsewhere.id)
        }
        return .nothing
    }
}
