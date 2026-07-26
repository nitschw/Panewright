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
    /// When the mouse was last held down. A manual resize or drag passes
    /// through overlapping states on its way somewhere, and correcting them
    /// mid-gesture means fighting the person doing the resizing.
    private var lastInteraction = Date.distantPast

    private static let maxAttempts = 5
    /// How long to leave a workspace alone after moving a window out of it.
    ///
    /// Evicting changes the problem: the windows that remain have more room,
    /// and usually now fit. Deciding again immediately — off geometry that
    /// hasn't re-tiled yet — is how one necessary eviction became three, and
    /// split a workspace that only ever needed to lose a single window.
    private static let evictionCooldown: TimeInterval = 4
    /// How long after letting go of the mouse before a window may be evicted.
    /// Long enough to cover a pause mid-adjustment, short enough that a layout
    /// genuinely too full still resolves without being touched again.
    private static let settleAfterInteraction: TimeInterval = 3
    private var lastEviction = Date.distantPast
    /// The window set at the moment of the last eviction. Nothing else moves
    /// until this differs from what's actually on screen.
    private var evictedFrom: Set<UInt32> = []
    /// Windows moved out recently, and when.
    ///
    /// The set-based guard compares the whole workspace, so it passes as soon
    /// as *any* window changes — which let the same window be evicted twice,
    /// the second time to the workspace it was already on. Remembering the
    /// window itself is what makes that impossible rather than unlikely.
    private var recentlyEvicted: [UInt32: Date] = [:]
    private static let reEvictionGuard: TimeInterval = 10

    /// Cached workspace membership, refreshed only when the on-screen window
    /// set changes — see currentWindows.
    private var cachedBundleIDs: [UInt32: String] = [:]
    private var cachedFloating: Set<UInt32> = []
    /// Windows currently filling the display. Kept separately from the tiled
    /// set so they're left out of fitting, and raised like floaters — a
    /// fullscreen window covered by a tiled one is plainly wrong.
    private var fullscreenIDs: Set<UInt32> = []
    private var cachedWindowIDs: Set<UInt32> = []
    private var cachedAt = Date.distantPast

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
        minimums.load()
        // Heal a cache poisoned by an earlier build before trusting any of it.
        if let screen = NSScreen.main {
            minimums.discardImplausible(
                displayWidth: screen.frame.width, displayHeight: screen.frame.height)
            minimums.save()
        }
    }

    func start() {
        stop()
        // Fast enough that a broken layout is corrected before it registers as
        // wrong. Affordable because the per-tick cost is one CGWindowList
        // call: the `aerospace` process is only spawned when the geometry has
        // actually moved (see currentWindows).
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
        // Any button held means a drag or a resize is in progress. Cheap,
        // synchronous, and needs no permission — and it's the difference
        // between a helper and something that undoes your work as you do it.
        if NSEvent.pressedMouseButtons != 0 {
            lastInteraction = Date()
            consecutiveOverlaps = 0
            return
        }
        let windows = currentWindows(cli: cli)
        prune(to: windows)
        if config.fitting.floatOnTop { raiseFloaters() }
        guard windows.count > 1 else {
            reset()
            return
        }
        // Every window seen is evidence about its floor: it cannot be larger
        // than the size the window is actually at.
        var corrected = false
        for window in windows {
            for axis in WindowFitting.Axis.allCases {
                let before = minimums.minimum(for: window.bundleID, axis: axis)
                minimums.observe(
                    bundleID: window.bundleID, axis: axis, size: axis.extent(window.frame))
                if before != minimums.minimum(for: window.bundleID, axis: axis) {
                    corrected = true
                }
            }
        }
        if corrected { minimums.save() }
        let bounds = displayBounds(config)
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
        let started = Date()
        Task { @MainActor in
            defer {
                converging = false
                consecutiveOverlaps = 0
            }
            // Fetched once per round and carried forward: the frames read
            // back after a resize are the same frames the next decision needs,
            // and querying twice was most of the time this loop spent.
            var windows = currentWindows(cli: cli)
            for attempt in 1...Self.maxAttempts {
                guard windows.count > 1 else { return }
                let verdict = WindowFitting.nextStep(
                    for: windows, minimums: minimums.minimums, bounds: bounds,
                    separation: separation, step: config.fitting.step,
                    usable: CGFloat(config.fitting.minimumUsable),
                    overflowEnabled: config.fitting.overflow)
                switch verdict {
                case .fits:
                    if attempt > 1 {
                        DragLog.log(
                            "fitting: settled after \(attempt - 1) steps in "
                                + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
                    }
                    settled = nil
                    return
                case .cannotFit(let count):
                    // Overflow is off, so this is the user's choice. Record it
                    // and stop pestering until something actually changes.
                    DragLog.log("fitting: \(count) windows don't fit and overflow is off")
                    settled = signature(of: windows)
                    return
                case .adjusting(.evict(let id)):
                    if let when = recentlyEvicted[id],
                        Date().timeIntervalSince(when) < Self.reEvictionGuard
                    {
                        DragLog.log("fitting: \(id) was just moved — not moving it again")
                        return
                    }
                    // Unchanged window set means the last eviction hasn't
                    // landed yet — but only for as long as landing plausibly
                    // takes. Without the time bound this deadlocks: move the
                    // same windows back onto the workspace and the set matches
                    // the one we evicted from, so it waits forever for a
                    // change that already happened and was undone.
                    guard evictedFrom != Set(windows.map(\.id))
                        || Date().timeIntervalSince(lastEviction) >= Self.evictionCooldown
                    else {
                        DragLog.log("fitting: waiting for the last eviction to take effect")
                        return
                    }
                    // Before moving anyone's window to another workspace,
                    // check that the floors saying it's impossible are real.
                    //
                    // A floor is only ever lowered by seeing a window smaller
                    // than it — and we never ask a window to go below its
                    // recorded floor, so it never gets seen smaller. One
                    // pessimistic measurement (an app mid-animation, or busy)
                    // therefore sticks forever and keeps forcing evictions on
                    // layouts that would fit. Eviction is destructive enough
                    // to be worth one round of proving the constraint first.
                    if await retestFloors(windows: windows, separation: separation, cli: cli) {
                        DragLog.log("fitting: a floor was wrong — resizing instead of evicting")
                        continue
                    }
                    // Never move a window out from under someone who was just
                    // resizing. Shrinking is recoverable by dragging back;
                    // eviction sends the window to another workspace, which
                    // during hands-on layout work reads as losing it.
                    guard
                        Date().timeIntervalSince(lastInteraction) >= Self.settleAfterInteraction
                    else {
                        DragLog.log("fitting: not evicting — you were just resizing")
                        return
                    }
                    guard Date().timeIntervalSince(lastEviction) >= Self.evictionCooldown
                    else {
                        // Let the previous eviction land and the layout re-tile
                        // before concluding anything else has to go.
                        DragLog.log("fitting: holding off — just evicted a window")
                        return
                    }
                    evict(id: id, windows: windows, cli: cli)
                    return
                case .adjusting(.shrink(let id, let by, let axis)):
                    guard let target = windows.first(where: { $0.id == id }) else { return }
                    try? cli.run([
                        "resize", "--window-id", "\(id)", axis.resizeDimension, "-\(by)",
                    ])
                    // Let the resize land before reading it back, or we learn
                    // a minimum from a frame that hadn't updated yet.
                    try? await Task.sleep(for: .milliseconds(15))
                    windows = currentWindows(cli: cli)
                    learn(from: target, requested: by, axis: axis, in: windows)
                case .adjusting(.settle):
                    return
                }
            }
            // Out of attempts. Before calling it a stalemate, ask once more:
            // those attempts existed to learn the floors, and the answer they
            // produce is often "these genuinely don't fit". Marking the layout
            // settled without asking meant the fitter proved a workspace was
            // impossible and then sat on the finding — four windows left
            // visibly overlapping, one of them off the edge of the screen,
            // with eviction never considered.
            windows = currentWindows(cli: cli)
            DragLog.log(
                "fitting: out of resize steps after "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
            let final = WindowFitting.nextStep(
                for: windows, minimums: minimums.minimums, bounds: bounds,
                separation: separation, step: config.fitting.step,
                usable: CGFloat(config.fitting.minimumUsable),
                overflowEnabled: config.fitting.overflow)
            if case .adjusting(.evict(let id)) = final,
                Date().timeIntervalSince(lastInteraction) >= Self.settleAfterInteraction,
                Date().timeIntervalSince(lastEviction) >= Self.evictionCooldown,
                evictedFrom != Set(windows.map(\.id)),
                recentlyEvicted[id].map({ Date().timeIntervalSince($0) >= Self.reEvictionGuard })
                    ?? true
            {
                evict(id: id, windows: windows, cli: cli)
                return
            }
            settled = signature(of: windows)
        }
    }

    /// Ask windows sitting on their recorded floor to shrink anyway.
    ///
    /// Returns true if any of them complied, which means that floor was too
    /// high and the layout may be fixable after all. Only windows with a
    /// neighbour to trade with are asked — the rest can't move regardless.
    private func retestFloors(
        windows: [WindowFitting.Window], separation: CGFloat, cli: AeroSpaceCLI
    ) async -> Bool {
        var improved = false
        for window in windows {
            for axis in WindowFitting.Axis.allCases {
                guard let floor = minimums.minimum(for: window.bundleID, axis: axis),
                    axis.extent(window.frame) <= floor + 4,
                    // Same rule the planner uses: a window alone in its column
                    // cannot give up height, so asking can only be refused —
                    // and that refusal gets misread as a floor. Re-testing was
                    // generating exactly the phantom measurements the planner
                    // already knows to avoid.
                    WindowFitting.hasNeighbour(
                        window, among: windows, along: axis, separation: separation)
                else { continue }
                let before = axis.extent(window.frame)
                try? cli.run([
                    "resize", "--window-id", "\(window.id)", axis.resizeDimension, "-40",
                ])
                try? await Task.sleep(for: .milliseconds(25))
                guard
                    let now = currentWindows(cli: cli).first(where: { $0.id == window.id })
                else { continue }
                let after = axis.extent(now.frame)
                if after < before - 1 {
                    // It moved, so the recorded floor was wrong. Record what
                    // it actually reached.
                    minimums.record(bundleID: window.bundleID, axis: axis, minimum: after)
                    minimums.save()
                    DragLog.log(
                        "fitting: \(window.bundleID) went below its recorded floor"
                            + " — now \(Int(after))pt \(axis.rawValue)")
                    improved = true
                }
            }
        }
        return improved
    }

    /// Compare a window against itself after a resize: what it gave up versus
    /// what it was asked for is the only signal macOS offers about its floor.
    private func learn(
        from target: WindowFitting.Window, requested: Int, axis: WindowFitting.Axis,
        in windows: [WindowFitting.Window]
    ) {
        guard let now = windows.first(where: { $0.id == target.id }) else { return }
        // An app's width floor and its height floor are unrelated numbers, so
        // each is measured along the axis it was actually asked about.
        guard
            let learned = WindowFitting.learnedMinimum(
                bundleID: target.bundleID, requested: requested,
                before: axis.extent(target.frame), after: axis.extent(now.frame))
        else { return }
        // A "minimum" near the size of the display is a resize that did
        // nothing, not a constraint the app expressed. Recording it would make
        // the app read as unshrinkable forever and push the fitter toward
        // evicting instead of resizing.
        if let screen = NSScreen.main,
            learned.minimum >= axis.extent(screen.frame) * 0.8
        {
            DragLog.log(
                "fitting: ignoring implausible \(learned.bundleID) floor of "
                    + "\(Int(learned.minimum))pt \(axis.rawValue)")
            return
        }
        DragLog.log(
            "fitting: learned \(learned.bundleID) won't go below "
                + "\(Int(learned.minimum))pt \(axis.rawValue)")
        minimums.record(bundleID: learned.bundleID, axis: axis, minimum: learned.minimum)
        minimums.save()
    }

    /// Is this window filling the display? A little tolerance, since a
    /// fullscreen frame can sit a point or two inside the screen rect.
    private func covers(_ frame: CGRect, _ display: CGRect) -> Bool {
        frame.width >= display.width * 0.98 && frame.height >= display.height * 0.95
    }

    /// The visible bounds of the display the focused workspace is on. A window
    /// pushed past this edge overlaps nothing and is still plainly broken.
    /// The region AeroSpace actually tiles into, in CGWindowList's top-left
    /// coordinates.
    ///
    /// Not the whole screen. AeroSpace insets the workspace by the outer gaps,
    /// and by the bar's reserved space at the bottom — so a window can be
    /// pushed below the tiled area, still be on screen, and be plainly wrong
    /// while a screen-sized bounds check calls it fine. That's exactly the
    /// "partially outside the tiled area" case a vertical resize leaves behind.
    ///
    /// The flip used not to matter, because only the horizontal extent was
    /// compared and it's identical in both coordinate systems. Now that height
    /// is fitted too, using NSScreen's bottom-left rect directly would put the
    /// insets on the wrong ends.
    private func displayBounds(_ config: PanewrightConfig) -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        let outer = CGFloat(config.gaps.outer)
        // The bar sits at the bottom, and the emitter adds its reserved height
        // to the bottom outer gap — mirror that rather than re-deriving it.
        let bottom =
            outer
            + (config.statusBar.enabled
                ? CGFloat(
                    SketchyBarConfigEmitter.reservedTopGap(for: config.statusBar.theme)) : 0)
        return CGRect(
            x: screen.frame.minX + outer,
            y: outer,
            width: screen.frame.width - outer * 2,
            height: screen.frame.height - outer - bottom)
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
        // Confirm it's still here, from AeroSpace rather than from our cache.
        // The cache only refreshes when the on-screen window set changes, so
        // it can still list a window that has already been moved away — and
        // moving it "again" lands it on the workspace it's already on.
        if let listing = try? cli.run([
            "list-windows", "--workspace", "focused", "--format", "%{window-id}",
        ]) {
            let here = Set(
                listing.split(separator: "\n").compactMap {
                    UInt32($0.trimmingCharacters(in: .whitespaces))
                })
            guard here.contains(id) else {
                DragLog.log("fitting: \(id) already left this workspace")
                return
            }
        }
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
            lastEviction = Date()
            // Wait for the window set to actually change before considering
            // another. Evicting removes a window, which frees space for the
            // ones left — deciding again off geometry that hasn't re-tiled is
            // how one necessary eviction became two, on a workspace that fit
            // perfectly well once the first window had gone.
            evictedFrom = Set(windows.map(\.id))
            recentlyEvicted[id] = Date()
            // Keep this from growing across a long session.
            recentlyEvicted = recentlyEvicted.filter {
                Date().timeIntervalSince($0.value) < Self.reEvictionGuard * 2
            }
            // On screen for a moment, and the reasoning in the log.
            //
            // A system notification is the wrong weight: it persists in
            // Notification Center and asks to be dismissed, for something that
            // stops being relevant the moment it's read. The arithmetic that
            // justified the move is worth keeping, but in the log rather than
            // in your face — the toast only has to answer "where did my window
            // go".
            Toast.show("\(name) moved to workspace \(destination) — it wouldn't fit")
            if let bounds = (try? Orchestrator().loadConfig()).flatMap({ displayBounds($0) }) {
                let capacity = WindowFitting.capacity(
                    of: windows, minimums: minimums.minimums, bounds: bounds,
                    separation: CGFloat((try? Orchestrator().loadConfig())?.gaps.inner ?? 0))
                if !capacity.explanation.isEmpty {
                    DragLog.log("fitting: \(capacity.explanation)")
                }
            }
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
        guard !cachedFloating.isEmpty || !fullscreenIDs.isEmpty else { return }
        let raised = FloatingWindowRaiser.raiseOccludedFloaters(
            onScreen: WindowSnapshot.capture(allLayers: true),
            floating: cachedFloating.union(fullscreenIDs),
            tiled: Set(cachedBundleIDs.keys).subtracting(fullscreenIDs))
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
        // The raw screen here, not the tiled area: this only rejects windows
        // parked far off-screen, and a window legitimately overlapping the bar
        // must still be seen so it can be corrected.
        let visible = NSScreen.main?.frame
        fullscreenIDs = []
        var windows: [WindowFitting.Window] = []
        for window in onScreen {
            guard let bundleID = cachedBundleIDs[window.id] else { continue }
            // AeroSpace hides windows by parking them far off-screen rather
            // than using Spaces, and a window parked in a bar pill is hidden
            // the same way. Mid-move, such a window can still be listed as
            // belonging to the focused workspace while its frame is nowhere
            // near the display — which reads as an enormous out-of-bounds
            // deficit that no resize can fix, so the only move left is to
            // evict it. That is what scattered real windows across workspaces
            // three times. A window with no pixels on the display isn't part
            // of the layout and has no business influencing it.
            if let visible, !window.frame.intersects(visible) { continue }
            // A window covering essentially the whole display isn't sharing it
            // with anyone, so it isn't tiling and must not be measured against
            // its neighbours.
            //
            // Judged on geometry rather than on AeroSpace's is-fullscreen flag,
            // which lags: for up to two seconds after the green button the app
            // is drawn fullscreen while still reported as tiled. In that gap it
            // looks like one window overlapping every other, nothing can shrink
            // to fix it, and the only move left is eviction — which is exactly
            // how full-screening an app kicked it to the next workspace.
            if let visible, covers(window.frame, visible) {
                fullscreenIDs.insert(window.id)
                continue
            }
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
