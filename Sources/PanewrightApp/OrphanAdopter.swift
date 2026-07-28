import AppKit
import ApplicationServices
import CoreGraphics
import PanewrightCore

/// Finds windows the engine doesn't manage — "free agents floating in the
/// nether" — and nudges them into adoption.
///
/// The engine discovers windows through AX notifications and per-app
/// enumeration on refresh, but a window can still slip through: apps whose
/// windows misreport their type until interacted with (Steam's undecorated
/// Chromium windows), or windows born while the engine was restarting. Such
/// a window belongs to no workspace — it lurks behind the tiling, appears in
/// no strip or overview, and then abruptly snaps into the grid the first
/// time it's clicked.
///
/// The nudge is an AX raise: making the window its app's main window fires
/// exactly the within-app notification the engine adopts on, without
/// activating the app or stealing the user's focus. An orphan must be seen
/// on two consecutive sweeps before it's touched (transient dialogs come and
/// go), and one that resists the nudge is logged once and left alone.
@MainActor
final class OrphanAdopter {
    private var timer: Timer?
    /// Orphans seen last sweep, awaiting confirmation.
    private var candidates: Set<UInt32> = []
    /// Windows we nudged, so a failed adoption is logged once, not forever.
    private var nudged: Set<UInt32> = []
    /// Last nudge per app. Some apps (Steam) churn helper windows with fresh
    /// ids continuously — without a cooldown every sweep found a "new"
    /// orphan to raise, and each raise could tug focus toward it: the user
    /// got dragged to that app's workspace every fifteen seconds.
    private var lastNudgeByApp: [String: Date] = [:]
    private static let perAppCooldown: TimeInterval = 600

    /// Owners that legitimately live outside the tiling.
    private static let infrastructure: Set<String> = [
        "Panewright", "sketchybar", "borders", "Window Server", "Dock",
        "Control Center", "Notification Center", "Spotlight", "SystemUIServer",
        "TextInputMenuAgent", "Wallpaper", "Screenshot", "loginwindow",
    ]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.sweep() }
        }
    }

    private func sweep() {
        guard !WakeGuard.isSettling,
            CGDisplayIsAsleep(CGMainDisplayID()) == 0,
            let cli = AeroSpaceCLI.locate(),
            let listing = try? cli.run(["list-windows", "--all", "--format", "%{window-id}"])
        else { return }
        let managed = Set(
            listing.split(separator: "\n").compactMap {
                UInt32($0.trimmingCharacters(in: .whitespaces))
            })
        // An engine that manages nothing is mid-restart, not surrounded by
        // orphans.
        guard !managed.isEmpty else {
            candidates = []
            return
        }
        var confirmed: [OnScreenWindow] = []
        var seen: Set<UInt32> = []
        for window in WindowSnapshot.capture() {
            guard !managed.contains(window.id),
                window.frame.width >= 200, window.frame.height >= 150,
                !Self.infrastructure.contains(window.ownerName),
                NSRunningApplication(processIdentifier: window.ownerPID)?
                    .activationPolicy == .regular
            else { continue }
            seen.insert(window.id)
            if candidates.contains(window.id) { confirmed.append(window) }
        }
        candidates = seen
        guard !confirmed.isEmpty else { return }
        // The raise can tug OS focus to the raised window, and the engine
        // follows focus — an adoption nudge must never cost the user their
        // workspace. Remember where they were; put them back if it moved.
        let focusedBefore = (try? cli.run(["list-workspaces", "--focused"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var raisedAny = false
        for window in confirmed {
            if nudged.contains(window.id) { continue }
            if let last = lastNudgeByApp[window.ownerName],
                Date().timeIntervalSince(last) < Self.perAppCooldown
            {
                continue
            }
            nudged.insert(window.id)
            if nudged.count > 512 { nudged = [window.id] }
            lastNudgeByApp[window.ownerName] = Date()
            if Self.raise(window) {
                raisedAny = true
                DragLog.log(
                    "orphan: \(window.ownerName) (\(window.id)) has no workspace"
                        + " — raised it for adoption")
            } else {
                DragLog.log(
                    "orphan: \(window.ownerName) (\(window.id)) has no workspace"
                        + " and resisted the nudge — leaving it alone")
            }
        }
        guard raisedAny, let focusedBefore, !focusedBefore.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            let now = (try? cli.run(["list-workspaces", "--focused"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let now, now != focusedBefore {
                DragLog.log("orphan: nudge moved focus \(focusedBefore) → \(now) — restoring")
                _ = try? cli.run(["workspace", focusedBefore])
            }
        }
    }

    /// The same public-API CG→AX bridge the raiser uses: match the window by
    /// owner and geometry, then perform kAXRaiseAction.
    private static func raise(_ window: OnScreenWindow) -> Bool {
        let app = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return false }
        guard
            let match = windows.first(where: { element in
                var pos: CFTypeRef?
                var size: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(
                        element, kAXPositionAttribute as CFString, &pos) == .success,
                    AXUIElementCopyAttributeValue(
                        element, kAXSizeAttribute as CFString, &size) == .success,
                    let posBox = pos, CFGetTypeID(posBox) == AXValueGetTypeID(),
                    let sizeBox = size, CFGetTypeID(sizeBox) == AXValueGetTypeID()
                else { return false }
                var origin = CGPoint.zero
                var extent = CGSize.zero
                guard AXValueGetValue(posBox as! AXValue, .cgPoint, &origin),
                    AXValueGetValue(sizeBox as! AXValue, .cgSize, &extent)
                else { return false }
                return abs(origin.x - window.frame.minX) < 3
                    && abs(origin.y - window.frame.minY) < 3
                    && abs(extent.width - window.frame.width) < 3
                    && abs(extent.height - window.frame.height) < 3
            })
        else { return false }
        return AXUIElementPerformAction(match, kAXRaiseAction as CFString) == .success
    }
}
