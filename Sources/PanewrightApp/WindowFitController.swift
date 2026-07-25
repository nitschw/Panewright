import AppKit
import CoreGraphics
import Foundation
import PanewrightCore

/// Watches the focused workspace for windows rendering over each other, and
/// corrects it.
///
/// The loop is observe → nudge → observe, not solve-and-apply, because
/// AeroSpace redistributes freed space on its own terms (see `WindowFitting`).
/// That makes every correction a small experiment: ask one window for some
/// width, look at what actually happened, and use the answer both to decide
/// the next step and to learn that app's floor.
@MainActor
final class WindowFitController {
    private let notify: (String) -> Void
    private var timer: Timer?
    private var minimums = MinimumSizeStore.default()

    /// First time each window was seen, so "newest arrival" means something.
    /// Keyed by window id; entries for windows that have gone away are pruned
    /// each pass so this can't grow without bound.
    private var firstSeen: [UInt32: Date] = [:]

    /// A shrink we asked for and haven't measured yet. The measurement is the
    /// entire point — it's how a minimum gets learned — so it must survive to
    /// the next pass.
    private struct PendingShrink {
        let id: UInt32
        let bundleID: String
        let requested: Int
        let widthBefore: CGFloat
    }
    private var pending: PendingShrink?

    /// Overlap must be seen twice running before anything moves. Windows are
    /// legitimately mid-flight during an animation or a workspace switch, and
    /// correcting a layout that was about to settle on its own is how a
    /// tiling manager gets into a fight with itself.
    private var consecutiveOverlaps = 0
    /// Passes spent trying to fix the current situation. Bounded so a layout
    /// we cannot fix becomes a quiet stalemate rather than an endless churn of
    /// resize commands.
    private var attempts = 0
    private var lastAction = Date.distantPast
    /// Set when we've given up on the present arrangement; cleared as soon as
    /// the windows change, since that's a genuinely new situation.
    private var stalemate: Set<UInt32> = []

    private static let maxAttempts = 8
    private static let cooldown: TimeInterval = 1.5

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
        minimums.load()
    }

    func start() {
        stop()
        // Two seconds matches the bar's spaces driver. CGWindowList is cheap,
        // and nothing here runs unless windows actually overlap.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let cli = AeroSpaceCLI.locate(),
            let config = try? Orchestrator().loadConfig(), config.fitting.enabled
        else { return }
        let windows = currentWindows(cli: cli)
        prune(to: windows)
        guard windows.count > 1 else {
            reset()
            return
        }
        // Measure the previous nudge before deciding anything new — this is
        // where minimums come from.
        settlePendingShrink(windows: windows)

        let verdict = WindowFitting.nextStep(
            for: windows, minimums: minimums.widths,
            step: config.fitting.step, overflowEnabled: config.fitting.overflow)

        switch verdict {
        case .fits:
            reset()
        case .cannotFit(let count):
            // Overflow is off, so this is the user's choice. Say it once, then
            // stop pestering.
            if !stalemate.isEmpty { return }
            stalemate = Set(windows.map(\.id))
            DragLog.log("fitting: \(count) windows overlap and overflow is off")
        case .adjusting(let action):
            guard shouldAct(on: windows) else { return }
            apply(action, windows: windows, cli: cli)
        }
    }

    /// Damping. Every guard here exists to stop the corrector from fighting
    /// either AeroSpace or itself.
    private func shouldAct(on windows: [WindowFitting.Window]) -> Bool {
        if stalemate == Set(windows.map(\.id)) { return false }
        consecutiveOverlaps += 1
        guard consecutiveOverlaps >= 2 else { return false }
        guard Date().timeIntervalSince(lastAction) >= Self.cooldown else { return false }
        guard attempts < Self.maxAttempts else {
            if stalemate.isEmpty {
                stalemate = Set(windows.map(\.id))
                DragLog.log("fitting: giving up after \(attempts) attempts")
            }
            return false
        }
        return true
    }

    private func apply(
        _ action: WindowFitting.Action, windows: [WindowFitting.Window], cli: AeroSpaceCLI
    ) {
        lastAction = Date()
        attempts += 1
        switch action {
        case .settle:
            break
        case .shrink(let id, let by):
            guard let target = windows.first(where: { $0.id == id }) else { return }
            DragLog.log("fitting: asking \(target.bundleID) for \(by)pt")
            try? cli.run(["resize", "--window-id", "\(id)", "width", "-\(by)"])
            pending = PendingShrink(
                id: id, bundleID: target.bundleID, requested: by,
                widthBefore: target.frame.width)
        case .evict(let id):
            evict(id: id, windows: windows, cli: cli)
        }
    }

    /// Move the newest arrival out, and always say so. A window vanishing from
    /// a workspace with no explanation reads as a bug, not a feature.
    private func evict(id: UInt32, windows: [WindowFitting.Window], cli: AeroSpaceCLI) {
        guard let destination = firstEmptyWorkspace(cli: cli) else {
            DragLog.log("fitting: nothing fits but there's no empty workspace to use")
            stalemate = Set(windows.map(\.id))
            return
        }
        let name = appName(for: id, windows: windows)
        do {
            try cli.run([
                "move-node-to-workspace", "--window-id", "\(id)", destination,
            ])
            notify("\(name) moved to workspace \(destination) — it wouldn't fit")
            DragLog.log("fitting: evicted \(name) (\(id)) to workspace \(destination)")
            reset()
        } catch {
            DragLog.log("fitting: eviction failed: \(error)")
            stalemate = Set(windows.map(\.id))
        }
    }

    /// What the last shrink actually achieved, which is the only source of
    /// minimum-size knowledge we have.
    private func settlePendingShrink(windows: [WindowFitting.Window]) {
        guard let shrink = pending else { return }
        pending = nil
        guard let now = windows.first(where: { $0.id == shrink.id }) else { return }
        guard
            let learned = WindowFitting.learnedMinimum(
                bundleID: shrink.bundleID, requested: shrink.requested,
                before: shrink.widthBefore, after: now.frame.width)
        else { return }
        DragLog.log("fitting: learned \(learned.bundleID) won't go below \(Int(learned.minimum))pt")
        minimums.record(bundleID: learned.bundleID, minimum: learned.minimum)
        minimums.save()
    }

    // MARK: Reading the world

    /// Join AeroSpace's idea of the workspace (which windows are tiled, and
    /// what app they belong to) with the actual frames from CGWindowList.
    /// AeroSpace has no geometry and CGWindowList has no workspace, so neither
    /// is sufficient alone. The window id is the same number in both.
    private func currentWindows(cli: AeroSpaceCLI) -> [WindowFitting.Window] {
        guard
            let listing = try? cli.run([
                "list-windows", "--workspace", "focused",
                "--format", "%{window-id}|%{app-bundle-id}",
            ])
        else { return [] }
        var bundleIDs: [UInt32: String] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let id = UInt32(parts[0]) else { continue }
            bundleIDs[id] = parts[1]
        }
        guard !bundleIDs.isEmpty else { return [] }
        let now = Date()
        var windows: [WindowFitting.Window] = []
        for onScreen in WindowSnapshot.capture(allLayers: true) {
            guard let bundleID = bundleIDs[onScreen.id] else { continue }
            let arrived = firstSeen[onScreen.id] ?? now
            firstSeen[onScreen.id] = arrived
            windows.append(
                WindowFitting.Window(
                    id: onScreen.id, bundleID: bundleID, frame: onScreen.frame,
                    arrived: arrived))
        }
        return windows
    }

    private func firstEmptyWorkspace(cli: AeroSpaceCLI) -> String? {
        guard
            let output = try? cli.run([
                "list-workspaces", "--monitor", "focused", "--empty",
            ])
        else { return nil }
        return output.split(separator: "\n").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func appName(for id: UInt32, windows: [WindowFitting.Window]) -> String {
        // The bundle ID is what we have; its last component reads better than
        // the whole reverse-DNS string in a notification.
        guard let window = windows.first(where: { $0.id == id }) else { return "A window" }
        return window.bundleID.split(separator: ".").last.map(String.init) ?? window.bundleID
    }

    // MARK: Bookkeeping

    private func reset() {
        consecutiveOverlaps = 0
        attempts = 0
        stalemate = []
        pending = nil
    }

    /// Drop remembered arrival times for windows that are gone, and treat any
    /// change in the window set as a fresh situation worth trying again.
    private func prune(to windows: [WindowFitting.Window]) {
        let live = Set(windows.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }
        if !stalemate.isEmpty, stalemate != live {
            stalemate = []
            attempts = 0
        }
    }
}
