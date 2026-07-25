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

    /// Overlap must be seen twice running before anything moves.
    private var consecutiveOverlaps = 0
    /// True while a convergence burst is in flight, so the timer can't start a
    /// second one on top of it.
    private var converging = false
    /// The layout we've already given up on, as a position-and-size signature.
    ///
    /// Keyed on geometry rather than on the set of window ids, which was the
    /// bug: once stuck, resizing a window by hand changed nothing about *which*
    /// windows were present, so the corrector stayed given-up and appeared to
    /// need poking before it would do anything.
    private var settled: String?

    private static let maxAttempts = 8

    /// Cached workspace membership, refreshed only when the on-screen window
    /// set changes — see currentWindows.
    private var cachedBundleIDs: [UInt32: String] = [:]
    private var cachedFloating: Set<UInt32> = []
    private var cachedWindowIDs: Set<UInt32> = []
    private var cachedAt = Date.distantPast

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
        minimums.load()
    }

    func start() {
        stop()
        // Fast enough that a broken layout is corrected before it registers as
        // wrong. Affordable because the per-tick cost is one CGWindowList
        // call: the `aerospace` process is only spawned when the geometry has
        // actually moved (see currentWindows).
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !converging,
            let cli = AeroSpaceCLI.locate(),
            let config = try? Orchestrator().loadConfig(), config.fitting.enabled
        else { return }
        let windows = currentWindows(cli: cli)
        prune(to: windows)
        if config.fitting.floatOnTop { raiseFloaters() }
        guard windows.count > 1 else {
            reset()
            return
        }
        let bounds = displayBounds()
        let separation = CGFloat(config.gaps.inner)
        let broken = WindowFitting.Axis.allCases.contains {
            WindowFitting.deficit(
                in: windows, bounds: bounds, separation: separation, axis: $0) > 0
        }
        guard broken else {
            reset()
            return
        }
        if signature(of: windows) == settled { return }
        // Windows are legitimately mid-flight during an animation or a
        // workspace switch. Correcting a layout that was about to settle on
        // its own is how this turns into a tug of war with AeroSpace.
        consecutiveOverlaps += 1
        guard consecutiveOverlaps >= 2 else { return }
        converge(cli: cli, config: config, bounds: bounds, separation: separation)
    }

    /// Fix it in one burst rather than one nudge per tick.
    ///
    /// Each correction is visible, so spreading eight of them across sixteen
    /// seconds reads as the window manager glitching once a second. Reading
    /// frames back costs a CGWindowList call — cheap enough to re-measure
    /// immediately — so the whole convergence happens in a few hundred
    /// milliseconds and looks like one reflow.
    private func converge(
        cli: AeroSpaceCLI, config: PanewrightConfig, bounds: CGRect?, separation: CGFloat
    ) {
        converging = true
        Task { @MainActor in
            defer {
                converging = false
                consecutiveOverlaps = 0
            }
            for attempt in 1...Self.maxAttempts {
                let windows = currentWindows(cli: cli)
                guard windows.count > 1 else { return }
                let verdict = WindowFitting.nextStep(
                    for: windows, minimums: minimums.minimums, bounds: bounds,
                    separation: separation, step: config.fitting.step,
                    overflowEnabled: config.fitting.overflow)
                switch verdict {
                case .fits:
                    if attempt > 1 { DragLog.log("fitting: settled after \(attempt - 1) steps") }
                    settled = nil
                    return
                case .cannotFit(let count):
                    // Overflow is off, so this is the user's choice. Record it
                    // and stop pestering until something actually changes.
                    DragLog.log("fitting: \(count) windows don't fit and overflow is off")
                    settled = signature(of: windows)
                    return
                case .adjusting(.evict(let id)):
                    evict(id: id, windows: windows, cli: cli)
                    return
                case .adjusting(.shrink(let id, let by, let axis)):
                    guard let target = windows.first(where: { $0.id == id }) else { return }
                    try? cli.run([
                        "resize", "--window-id", "\(id)", axis.resizeDimension, "-\(by)",
                    ])
                    // Let the resize land before reading it back, or we learn
                    // a minimum from a frame that hadn't updated yet.
                    try? await Task.sleep(for: .milliseconds(90))
                    learn(from: target, requested: by, axis: axis, cli: cli)
                case .adjusting(.settle):
                    return
                }
            }
            // Bounded so a layout we cannot fix becomes a quiet stalemate
            // rather than an endless churn of resize commands.
            let windows = currentWindows(cli: cli)
            DragLog.log("fitting: giving up after \(Self.maxAttempts) steps")
            settled = signature(of: windows)
        }
    }

    /// Compare a window against itself after a resize: what it gave up versus
    /// what it was asked for is the only signal macOS offers about its floor.
    private func learn(
        from target: WindowFitting.Window, requested: Int, axis: WindowFitting.Axis,
        cli: AeroSpaceCLI
    ) {
        guard let now = currentWindows(cli: cli).first(where: { $0.id == target.id }) else {
            return
        }
        // An app's width floor and its height floor are unrelated numbers, so
        // each is measured along the axis it was actually asked about.
        guard
            let learned = WindowFitting.learnedMinimum(
                bundleID: target.bundleID, requested: requested,
                before: axis.extent(target.frame), after: axis.extent(now.frame))
        else { return }
        DragLog.log(
            "fitting: learned \(learned.bundleID) won't go below "
                + "\(Int(learned.minimum))pt \(axis.rawValue)")
        minimums.record(bundleID: learned.bundleID, axis: axis, minimum: learned.minimum)
        minimums.save()
    }

    /// The visible bounds of the display the focused workspace is on. A window
    /// pushed past this edge overlaps nothing and is still plainly broken.
    private func displayBounds() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        // CGWindowList is top-left origin; NSScreen is bottom-left. Only the
        // horizontal extent is compared, so the flip doesn't matter here.
        return CGRect(
            x: screen.frame.minX, y: screen.frame.minY,
            width: screen.frame.width, height: screen.frame.height)
    }

    /// Identity of a layout: which windows, and roughly where. Rounded so
    /// sub-point jitter doesn't read as a change, but any real move or resize
    /// does — including one the user makes by hand, which has to count as a
    /// new situation worth retrying.
    private func signature(of windows: [WindowFitting.Window]) -> String {
        windows
            .sorted { $0.id < $1.id }
            .map {
                "\($0.id):\(Int($0.frame.minX / 4)):\(Int($0.frame.minY / 4))"
                    + ":\(Int($0.frame.width / 4)):\(Int($0.frame.height / 4))"
            }
            .joined(separator: ",")
    }

    /// Move the newest arrival out, and always say so. A window vanishing from
    /// a workspace with no explanation reads as a bug, not a feature.
    private func evict(id: UInt32, windows: [WindowFitting.Window], cli: AeroSpaceCLI) {
        guard let destination = firstEmptyWorkspace(cli: cli) else {
            DragLog.log("fitting: nothing fits but there's no empty workspace to use")
            settled = signature(of: windows)
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
            settled = signature(of: windows)
        }
    }

    /// A floating window covered by a tiled one defeats the point of floating
    /// it. Only ever acts when that's actually happening, so it can't fight the
    /// user for control of their own stacking.
    private func raiseFloaters() {
        guard !cachedFloating.isEmpty else { return }
        let raised = FloatingWindowRaiser.raiseOccludedFloaters(
            onScreen: WindowSnapshot.capture(allLayers: true),
            floating: cachedFloating,
            tiled: Set(cachedBundleIDs.keys))
        if !raised.isEmpty {
            DragLog.log("fitting: raised floating window(s) \(raised) above the tiling")
        }
    }

    // MARK: Reading the world

    private func currentWindows(cli: AeroSpaceCLI) -> [WindowFitting.Window] {
        let onScreen = WindowSnapshot.capture(allLayers: true)
        let live = Set(onScreen.map(\.id))
        // Which windows are tiled here changes far more slowly than where they
        // are, so the answer is cached and only re-fetched when the set of
        // on-screen windows changes (or the cache ages out). That keeps the
        // polling loop down to one CGWindowList call, which is what makes a
        // sub-second cadence affordable.
        if live != cachedWindowIDs || Date().timeIntervalSince(cachedAt) > 2 {
            let listing = fetchWorkspace(cli: cli)
            cachedBundleIDs = listing.tiled
            cachedFloating = listing.floating
            cachedWindowIDs = live
            cachedAt = Date()
        }
        guard !cachedBundleIDs.isEmpty else { return [] }
        let now = Date()
        var windows: [WindowFitting.Window] = []
        for window in onScreen {
            guard let bundleID = cachedBundleIDs[window.id] else { continue }
            let arrived = firstSeen[window.id] ?? now
            firstSeen[window.id] = arrived
            windows.append(
                WindowFitting.Window(
                    id: window.id, bundleID: bundleID, frame: window.frame, arrived: arrived))
        }
        return windows
    }

    /// Join AeroSpace's idea of the workspace (which windows are tiled, and
    /// what app they belong to) with the frames from CGWindowList. AeroSpace
    /// has no geometry and CGWindowList has no workspace, so neither is
    /// sufficient alone. The window id is the same number in both.
    ///
    /// Only genuinely tiled windows are returned. A floating window isn't part
    /// of the layout — it's deliberately sitting on top of it — so counting it
    /// would have the fitter endlessly resizing the tiled windows underneath
    /// to get away from something that is supposed to overlap them. Fullscreen
    /// windows are excluded for the same reason: one covers everything, which
    /// reads as a collision with every window at once.
    private func fetchWorkspace(
        cli: AeroSpaceCLI
    ) -> (tiled: [UInt32: String], floating: Set<UInt32>) {
        guard
            let listing = try? cli.run([
                "list-windows", "--workspace", "focused",
                "--format",
                "%{window-id}|%{app-bundle-id}|%{window-layout}|%{window-is-fullscreen}",
            ])
        else { return ([:], []) }
        var bundleIDs: [UInt32: String] = [:]
        var floating: Set<UInt32> = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 4, let id = UInt32(parts[0]) else { continue }
            if parts[2] == "floating" {
                floating.insert(id)
                continue
            }
            guard parts[3] != "true" else { continue }
            bundleIDs[id] = parts[1]
        }
        return (bundleIDs, floating)
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
        settled = nil
    }

    /// Drop remembered arrival times for windows that are gone, so this can't
    /// grow without bound.
    private func prune(to windows: [WindowFitting.Window]) {
        let live = Set(windows.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }
    }
}
