import AppKit
import PanewrightCore

/// Native macOS Spaces are a dimension the tiling model deliberately doesn't
/// manage: the engine's workspaces *replace* Spaces, and everything here
/// assumes one Space per display. But users arrive with extra Spaces (and
/// fullscreen apps mint them), and switching to one makes every window on
/// the departed Space invisible to CGWindowList — the fitter would see a
/// workspace's members vanish mid-tick and "correct" the survivors.
///
/// Two duties: on every native Space change, stamp the same hold the
/// workspace-switch dispatch uses (the fitter and friends stand down while
/// the world is half-visible), and — once per session — tell the user the
/// model, because "my windows vanished and tiling broke" on a second Space
/// is working-as-designed in the worst way unless someone explains it.
@MainActor
final class SpaceGuard {
    /// When the user last moved between native Spaces — consulted by the
    /// engine stall detector, because an engine that manages zero windows
    /// is *also* what a healthy engine looks like from a foreign Space
    /// (windows on inactive Spaces are invisible to AX, and the engine
    /// garbage-collects them from its tree). Restarting it on that
    /// evidence exploded every window twice in one session (issue #22).
    private(set) static var lastSpaceChange = Date.distantPast

    private var observing = false
    private var advisoryGiven = false
    private let notify: (String) -> Void

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
    }

    func start() {
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    private func spaceChanged() {
        Self.lastSpaceChange = Date()
        DragLog.log("space: native macOS Space changed — holding corrections")
        // The same stamp the workspace-switch dispatch writes: the fitter's
        // tick holds while it's fresh, which is exactly right for a Space
        // transition too — windows are appearing and disappearing wholesale.
        let stamp = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/panewright/.last-switch")
        FileManager.default.createFile(atPath: stamp.path, contents: nil)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: stamp.path)
        if !advisoryGiven {
            advisoryGiven = true
            notify(
                "Heads up: this Mac uses multiple macOS Spaces. Panewright's"
                    + " workspaces replace Spaces — windows on another Space are"
                    + " invisible to tiling until you return. One Space per"
                    + " display works best; $mod+1…9 does the rest.")
        }
    }
}
