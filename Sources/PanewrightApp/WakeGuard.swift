import AppKit

/// Nothing observed just after a wake is trustworthy.
///
/// Displays come back before the rest of the system has caught up, and for a
/// second or two everything Panewright watches looks broken in a way it isn't:
/// AeroSpace has not re-established its Accessibility connection so it reports
/// managing zero windows, SketchyBar has not redrawn so it reads as not
/// running, and every window frame is one it is about to stop having.
///
/// Each watcher then does the reasonable thing for a system that really was
/// broken. AeroSpace gets restarted, the bar gets rebuilt item by item, and a
/// window is evicted for not fitting a layout that hadn't happened yet. That
/// is the whole of "opening the lid makes everything restart", and it is three
/// separate mechanisms agreeing on the same wrong conclusion — so the pause
/// belongs in one place they all consult, not in each of them.
///
/// The quietest damage is the measuring. A window still restoring refuses to
/// resize because it is busy, not because it has hit its floor, and that
/// refusal gets written down as the app's minimum size. One wake produced a
/// 752pt floor for a terminal and forced evictions for hours afterwards.
@MainActor
enum WakeGuard {
    private static var lastWake = Date.distantPast

    /// Long enough for the displays, AeroSpace and the bar to come back —
    /// AeroSpace reconnecting to Accessibility is the slow one. Short enough
    /// that something genuinely broken across a sleep still recovers on its
    /// own rather than waiting on the user.
    static let settle: TimeInterval = 8

    static var isSettling: Bool { Date().timeIntervalSince(lastWake) < settle }

    /// Registered once at launch. `didWake` covers the machine, and
    /// `screensDidWake` the displays alone — a clamshell open posts one and a
    /// lid open the other, and both want the same pause.
    private static var observing = false

    static func observe() {
        guard !observing else { return }
        observing = true
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    let wasSettling = isSettling
                    lastWake = Date()
                    // Both notifications usually arrive together; say it once.
                    if !wasSettling {
                        DragLog.log(
                            "wake: leaving windows, bar and AeroSpace alone for "
                                + "\(Int(settle))s")
                        // Sleep doesn't age the workspace snapshot: nothing
                        // can rearrange while the machine is off. The
                        // restore's staleness gate measures wall-clock time,
                        // so an overnight sleep made a perfectly valid
                        // snapshot look ancient — the engine relaunched at
                        // wake and restored nothing, leaving every monitor
                        // wrong until the user clicked around. Waking
                        // revalidates it.
                        let snapshot = FileManager.default.homeDirectoryForCurrentUser
                            .appending(path: ".config/panewright/.workspace-snapshot")
                        try? FileManager.default.setAttributes(
                            [.modificationDate: Date()], ofItemAtPath: snapshot.path)
                        // The pause is for ambiguous evidence; a process that
                        // is outright gone isn't ambiguous. Hand the wake to
                        // the fast-path so a dead engine or bar comes back in
                        // seconds instead of riding out the settle window.
                        AppDelegate.model?.wokeFromSleep()
                    }
                }
            }
        }
    }
}
