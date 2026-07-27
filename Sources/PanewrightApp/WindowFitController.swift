import AppKit
import CoreGraphics
import Foundation
import PanewrightCore

/// Watches every visible workspace — one per monitor — for windows rendering
/// over each other, and corrects it.
///
/// The loop is observe → nudge → observe, not solve-and-apply, because
/// AeroSpace redistributes freed space on its own terms (see `WindowFitting`).
/// That makes every correction a small experiment: ask one window for some
/// width, look at what actually happened, and use the answer both to decide
/// the next step and to learn that app's floor.
///
/// With one monitor there is exactly one visible workspace and this behaves
/// as it always has. With more, each workspace is fitted against the screen
/// its monitor actually occupies — bounds, parked-window filtering and
/// fullscreen detection all resolve per display, because a 2160-point
/// portrait panel and a laptop lid agree on nothing.
@MainActor
final class WindowFitController {
    private let notify: (String) -> Void
    private var timer: Timer?
    private var minimums = MinimumSizeStore.default()

    /// Everything the fitter knows about one workspace. Per-workspace rather
    /// than global because two monitors show two workspaces at once, and a
    /// membership change or an eviction on one must not reset the other's
    /// timers. A class so the dictionary hands out references — the converge
    /// burst mutates this across awaits, and copy-back bookkeeping is how
    /// state quietly forks.
    private final class WorkspaceState {
        /// First time each window was seen, so "newest arrival" means
        /// something. Entries for windows that have gone away are pruned each
        /// pass so this can't grow without bound.
        var firstSeen: [UInt32: Date] = [:]
        /// Overlap must be seen twice running before anything moves.
        var consecutiveOverlaps = 0
        /// The window set last tick, and when it last changed. A change means
        /// a workspace switch, a new window, or a closed one — all moments
        /// when frames are legitimately mid-flight. Correcting or *learning*
        /// against them is how bopping between two workspaces taught the
        /// fitter that Messages' minimum width is 885 points (it is 660) and
        /// evicted two windows in twenty seconds off the fiction: a
        /// mid-unpark window refuses a resize because it is busy, which is
        /// indistinguishable from hitting its floor.
        var lastMembership: Set<UInt32> = []
        var lastMembershipChange = Date.distantPast
        /// The layout we've already given up on, as a position-and-size
        /// signature.
        ///
        /// Keyed on geometry rather than on the set of window ids, which was
        /// the bug: once stuck, resizing a window by hand changed nothing
        /// about *which* windows were present, so the corrector stayed
        /// given-up and appeared to need poking before it would do anything.
        var settled: String?
        var lastEviction = Date.distantPast
        /// Same idea as the eviction cooldown: a join reshapes the tree, and
        /// judging the layout again before AeroSpace has settled reads chaos.
        var lastStack = Date.distantPast
        /// The window set at the moment of the last eviction. Nothing else
        /// moves until this differs from what's actually on screen.
        var evictedFrom: Set<UInt32> = []
        /// Windows moved out recently, and when.
        ///
        /// The set-based guard compares the whole workspace, so it passes as
        /// soon as *any* window changes — which let the same window be
        /// evicted twice, the second time to the workspace it was already on.
        /// Remembering the window itself is what makes that impossible rather
        /// than unlikely.
        var recentlyEvicted: [UInt32: Date] = [:]
        /// Cached workspace membership, refreshed only when the on-screen
        /// window set changes — see currentWindows.
        var cachedBundleIDs: [UInt32: String] = [:]
        var cachedFloating: Set<UInt32> = []
        /// Windows currently filling this display. Kept separately from the
        /// tiled set so they're left out of fitting, and raised like floaters
        /// — a fullscreen window covered by a tiled one is plainly wrong.
        var fullscreenIDs: Set<UInt32> = []
        var cachedWindowIDs: Set<UInt32> = []
        var cachedAt = Date.distantPast
        /// The last full record per window, so a close hook can still name
        /// the app that owned the now-gone window.
        var lastKnown: [UInt32: WindowFitting.Window] = [:]
    }

    private var states: [String: WorkspaceState] = [:]

    private func state(for workspace: String) -> WorkspaceState {
        if let existing = states[workspace] { return existing }
        let fresh = WorkspaceState()
        states[workspace] = fresh
        return fresh
    }

    /// The visible-workspace roster (workspace ↔ monitor ↔ screen), cached on
    /// the same policy as workspace membership: shelling out to AeroSpace
    /// four times a second is what the caching exists to avoid.
    private var visibleCache: [Monitors.VisibleWorkspace] = []
    private var visibleCacheIDs: Set<UInt32> = []
    private var visibleCachedAt = Date.distantPast

    /// True while a convergence burst is in flight, so the timer can't start
    /// a second one on top of it. Global rather than per-workspace: bursts
    /// resize through the same engine, and two running interleaved would
    /// each read the other's churn as refusals.
    private var converging = false
    /// When the mouse was last held down. A manual resize or drag passes
    /// through overlapping states on its way somewhere, and correcting them
    /// mid-gesture means fighting the person doing the resizing.
    private var lastInteraction = Date.distantPast

    /// Unpark plus retile settles well inside a second; churny moments
    /// (windows opening in bursts) just extend the quiet period.
    private static let membershipSettle: TimeInterval = 1.2
    private static let maxAttempts = 5
    /// How long to leave a workspace alone after moving a window out of it.
    ///
    /// Evicting changes the problem: the windows that remain have more room,
    /// and usually now fit. Deciding again immediately — off geometry that
    /// hasn't re-tiled yet — is how one necessary eviction became three, and
    /// split a workspace that only ever needed to lose a single window.
    private static let evictionCooldown: TimeInterval = 4
    /// How long after letting go of the mouse before a window may be evicted.
    /// Long enough to cover a pause mid-adjustment, short enough that a
    /// layout genuinely too full still resolves without being touched again.
    private static let settleAfterInteraction: TimeInterval = 3
    private static let reEvictionGuard: TimeInterval = 10

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
        minimums.load()
        // Heal a cache poisoned by an earlier build before trusting any of
        // it. Judged against the largest display present: a floor plausible
        // on any attached screen is a floor worth keeping.
        let widest = NSScreen.screens.map(\.frame.width).max()
        let tallest = NSScreen.screens.map(\.frame.height).max()
        if let widest, let tallest {
            minimums.discardImplausible(displayWidth: widest, displayHeight: tallest)
            minimums.save()
        }
    }

    func start() {
        stop()
        // Fast enough that a broken layout is corrected before it registers
        // as wrong. Affordable because the per-tick cost is one CGWindowList
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
        // Nothing measured just after a wake is trustworthy — not the frames,
        // and not a window's refusal to resize.
        guard !WakeGuard.isSettling else {
            for state in states.values { state.consecutiveOverlaps = 0 }
            return
        }
        // Any button held means a drag or a resize is in progress. Cheap,
        // synchronous, and needs no permission — and it's the difference
        // between a helper and something that undoes your work as you do it.
        if NSEvent.pressedMouseButtons != 0 {
            lastInteraction = Date()
            for state in states.values { state.consecutiveOverlaps = 0 }
            return
        }
        // One CGWindowList capture serves every workspace this tick.
        let onScreen = WindowSnapshot.capture(allLayers: true)
        let visible = visibleWorkspaces(cli: cli, onScreen: onScreen)
        if config.fitting.floatOnTop { raiseFloaters(onScreen: onScreen, among: visible) }
        for entry in visible {
            fit(entry, config: config, cli: cli, onScreen: onScreen)
            // A burst launched for one workspace owns the engine until it
            // settles; the others get their turn next tick.
            if converging { break }
        }
    }

    /// One workspace's tick: observe, learn floors, and start a convergence
    /// burst if the layout is genuinely broken two ticks running.
    private func fit(
        _ entry: Monitors.VisibleWorkspace, config: PanewrightConfig, cli: AeroSpaceCLI,
        onScreen: [OnScreenWindow]
    ) {
        let state = state(for: entry.workspace)
        let windows = currentWindows(
            cli: cli, workspace: entry.workspace, screen: entry.screen,
            state: state, onScreen: onScreen)
        prune(to: windows, state: state, config: config)
        let membership = Set(windows.map(\.id))
        if membership != state.lastMembership {
            state.lastMembership = membership
            state.lastMembershipChange = Date()
        }
        if Date().timeIntervalSince(state.lastMembershipChange) < Self.membershipSettle {
            state.consecutiveOverlaps = 0
            return
        }
        guard windows.count > 1 else {
            reset(state)
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
        let bounds = displayBounds(config, screen: entry.screen)
        let separation = CGFloat(config.gaps.inner)
        let broken = WindowFitting.Axis.allCases.contains {
            WindowFitting.deficit(
                in: windows, bounds: bounds, separation: separation, axis: $0) > 0
        }
        guard broken else {
            reset(state)
            return
        }
        if signature(of: windows) == state.settled { return }
        // Windows are legitimately mid-flight during an animation or a
        // workspace switch. Correcting a layout that was about to settle on
        // its own is how this turns into a tug of war with AeroSpace.
        state.consecutiveOverlaps += 1
        guard state.consecutiveOverlaps >= 2 else { return }
        converge(
            cli: cli, config: config, entry: entry, state: state,
            bounds: bounds, separation: separation)
    }

    /// Fix it in one burst rather than one nudge per tick.
    ///
    /// Each correction is visible, so spreading eight of them across sixteen
    /// seconds reads as the window manager glitching once a second. Reading
    /// frames back costs a CGWindowList call — cheap enough to re-measure
    /// immediately — so the whole convergence happens in a few hundred
    /// milliseconds and looks like one reflow.
    private func converge(
        cli: AeroSpaceCLI, config: PanewrightConfig, entry: Monitors.VisibleWorkspace,
        state: WorkspaceState, bounds: CGRect?, separation: CGFloat
    ) {
        converging = true
        let started = Date()
        Task { @MainActor in
            defer {
                converging = false
                state.consecutiveOverlaps = 0
            }
            // Fetched once per round and carried forward: the frames read
            // back after a resize are the same frames the next decision
            // needs, and querying twice was most of the time this loop spent.
            var windows = currentWindows(
                cli: cli, workspace: entry.workspace, screen: entry.screen, state: state)
            // Remembered so running out of steps can tell progress from a
            // stalemate. A window shoved far off-screen needs more correction
            // than one burst's step budget covers, and marking the layout
            // settled after a burst that was working meant recovery stopped
            // until the user jiggled something — "it takes a few clicks of
            // the resize to fully recover" was exactly this, each click
            // changing the signature and unlocking one more burst.
            let deficitAtStart = WindowFitting.Axis.allCases
                .map {
                    WindowFitting.deficit(
                        in: windows, bounds: bounds, separation: separation, axis: $0)
                }
                .max() ?? 0
            for attempt in 1...Self.maxAttempts {
                guard windows.count > 1 else { return }
                let verdict = WindowFitting.nextStep(
                    for: windows, minimums: minimums.minimums, bounds: bounds,
                    separation: separation, step: config.fitting.step,
                    usable: CGFloat(config.fitting.minimumUsable),
                    overflowEnabled: config.fitting.overflow,
                    honorPushOut: Date().timeIntervalSince(lastInteraction) < 10)
                switch verdict {
                case .fits:
                    if attempt > 1 {
                        DragLog.log(
                            "fitting: settled after \(attempt - 1) steps in "
                                + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
                    }
                    state.settled = nil
                    return
                case .cannotFit(let count):
                    // Overflow is off, so this is the user's choice. Record
                    // it and stop pestering until something actually changes.
                    DragLog.log("fitting: \(count) windows don't fit and overflow is off")
                    state.settled = signature(of: windows)
                    return
                case .adjusting(.evict(let id)):
                    if let when = state.recentlyEvicted[id],
                        Date().timeIntervalSince(when) < Self.reEvictionGuard
                    {
                        DragLog.log("fitting: \(id) was just moved — not moving it again")
                        return
                    }
                    // Unchanged window set means the last eviction hasn't
                    // landed yet — but only for as long as landing plausibly
                    // takes. Without the time bound this deadlocks: move the
                    // same windows back onto the workspace and the set
                    // matches the one we evicted from, so it waits forever
                    // for a change that already happened and was undone.
                    guard state.evictedFrom != Set(windows.map(\.id))
                        || Date().timeIntervalSince(state.lastEviction) >= Self.evictionCooldown
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
                    if await retestFloors(
                        windows: windows, workspace: entry.workspace, screen: entry.screen,
                        state: state, separation: separation,
                        usable: CGFloat(config.fitting.minimumUsable), cli: cli)
                    {
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
                    guard Date().timeIntervalSince(state.lastEviction) >= Self.evictionCooldown
                    else {
                        // Let the previous eviction land and the layout
                        // re-tile before concluding anything else has to go.
                        DragLog.log("fitting: holding off — just evicted a window")
                        return
                    }
                    evict(id: id, windows: windows, entry: entry, state: state, cli: cli)
                    return
                case .adjusting(.stack(let id, let with)):
                    // Structural, like eviction — never mid-gesture, never in
                    // a rapid burst, and once per settle so a failed join
                    // doesn't loop.
                    guard
                        Date().timeIntervalSince(lastInteraction) >= Self.settleAfterInteraction,
                        Date().timeIntervalSince(state.lastStack) >= Self.evictionCooldown,
                        let mover = windows.first(where: { $0.id == id }),
                        let target = windows.first(where: { $0.id == with })
                    else { return }
                    state.lastStack = Date()
                    let direction =
                        target.frame.midX < mover.frame.midX ? "left" : "right"
                    DragLog.log(
                        "fitting: columns don't fit — stacking \(mover.bundleID)"
                            + " (\(Int(mover.frame.width))pt) into"
                            + " \(target.bundleID)'s column")
                    guard
                        (try? cli.run(["join-with", "--window-id", "\(id)", direction])) != nil
                    else {
                        DragLog.log("fitting: join-with failed — leaving the layout alone")
                        state.settled = signature(of: windows)
                        return
                    }
                    // The tree reshapes more slowly than windows move; give
                    // it a beat, then let the next tick judge the new
                    // geometry fresh rather than acting on mid-transition
                    // frames.
                    try? await Task.sleep(for: .milliseconds(350))
                    state.consecutiveOverlaps = 0
                    return
                case .adjusting(.shrink(let id, let by, let axis)):
                    guard let target = windows.first(where: { $0.id == id }) else { return }
                    try? cli.run([
                        "resize", "--window-id", "\(id)", axis.resizeDimension, "-\(by)",
                    ])
                    // Let the resize land before reading it back, or we learn
                    // a minimum from a frame that hadn't updated yet.
                    try? await Task.sleep(for: .milliseconds(15))
                    windows = currentWindows(
                        cli: cli, workspace: entry.workspace, screen: entry.screen, state: state)
                    learn(
                        from: target, requested: by, axis: axis, in: windows,
                        screen: entry.screen)
                case .adjusting(.settle):
                    return
                }
            }
            // Out of attempts. Before calling it a stalemate, ask once more:
            // those attempts existed to learn the floors, and the answer they
            // produce is often "these genuinely don't fit". Marking the
            // layout settled without asking meant the fitter proved a
            // workspace was impossible and then sat on the finding — four
            // windows left visibly overlapping, one of them off the edge of
            // the screen, with eviction never considered.
            windows = currentWindows(
                cli: cli, workspace: entry.workspace, screen: entry.screen, state: state)
            DragLog.log(
                "fitting: out of resize steps after "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
            let final = WindowFitting.nextStep(
                for: windows, minimums: minimums.minimums, bounds: bounds,
                separation: separation, step: config.fitting.step,
                usable: CGFloat(config.fitting.minimumUsable),
                overflowEnabled: config.fitting.overflow,
                honorPushOut: Date().timeIntervalSince(lastInteraction) < 10)
            if case .adjusting(.evict(let id)) = final,
                Date().timeIntervalSince(lastInteraction) >= Self.settleAfterInteraction,
                Date().timeIntervalSince(state.lastEviction) >= Self.evictionCooldown,
                state.evictedFrom != Set(windows.map(\.id)),
                state.recentlyEvicted[id]
                    .map({ Date().timeIntervalSince($0) >= Self.reEvictionGuard }) ?? true
            {
                evict(id: id, windows: windows, entry: entry, state: state, cli: cli)
                return
            }
            // Give up only on a genuine stalemate. If this burst reduced the
            // deficit, the next tick gets another one — convergence continues
            // by itself instead of waiting for the user to nudge a window.
            let deficitNow = WindowFitting.Axis.allCases
                .map {
                    WindowFitting.deficit(
                        in: windows, bounds: bounds, separation: separation, axis: $0)
                }
                .max() ?? 0
            if deficitNow < deficitAtStart - 1 {
                DragLog.log(
                    "fitting: progress (\(Int(deficitAtStart)) → \(Int(deficitNow))pt)"
                        + " — continuing next tick")
                state.consecutiveOverlaps = 0
                return
            }
            state.settled = signature(of: windows)
        }
    }

    /// Ask windows sitting on their recorded floor to shrink anyway.
    ///
    /// Returns true if any of them complied, which means that floor was too
    /// high and the layout may be fixable after all. Only windows with a
    /// neighbour to trade with are asked — the rest can't move regardless.
    ///
    /// Never below a size worth having, and that bound is what stops this
    /// running away. Most apps' true minimum is far smaller than anything
    /// useful — iTerm will go to 87 points — so a window asked to prove its
    /// floor essentially always complies. That reads as "the floor was
    /// wrong", which skips the eviction and shrinks instead, and the next
    /// round asks again from the new smaller size. Six windows on one
    /// workspace drove iTerm from 228 points to 87 that way, in a couple of
    /// seconds, and the eviction the workspace genuinely needed never
    /// happened: there was always one more point to give. A window already
    /// down at the usable size has nothing left to prove, and asking only
    /// manufactures the evidence that blocks the eviction.
    private func retestFloors(
        windows: [WindowFitting.Window], workspace: String, screen: NSScreen,
        state: WorkspaceState, separation: CGFloat, usable: CGFloat,
        cli: AeroSpaceCLI
    ) async -> Bool {
        var improved = false
        for window in windows {
            for axis in WindowFitting.Axis.allCases {
                guard let floor = minimums.minimum(for: window.bundleID, axis: axis),
                    axis.extent(window.frame) <= floor + 4,
                    // Same rule the planner uses: a window alone in its
                    // column cannot give up height, so asking can only be
                    // refused — and that refusal gets misread as a floor.
                    // Re-testing was generating exactly the phantom
                    // measurements the planner already knows to avoid.
                    WindowFitting.hasNeighbour(
                        window, among: windows, along: axis, separation: separation)
                else { continue }
                let before = axis.extent(window.frame)
                // Ask only for what keeps it at a usable size, and don't ask
                // at all once there's nothing left worth reclaiming.
                let ask = min(CGFloat(40), before - usable)
                guard ask >= 8 else { continue }
                try? cli.run([
                    "resize", "--window-id", "\(window.id)", axis.resizeDimension,
                    "-\(Int(ask))",
                ])
                try? await Task.sleep(for: .milliseconds(25))
                guard
                    let now = currentWindows(
                        cli: cli, workspace: workspace, screen: screen, state: state
                    ).first(where: { $0.id == window.id })
                else { continue }
                let after = axis.extent(now.frame)
                if after < before - 1 {
                    // It moved, so the recorded floor was wrong. Record what
                    // it actually reached — or what a smaller sibling window
                    // of the same app already proves, whichever is lower.
                    let floor = WindowFitting.corroborated(
                        after, forBundleID: window.bundleID, among: windows, axis: axis)
                    minimums.record(bundleID: window.bundleID, axis: axis, minimum: floor)
                    minimums.save()
                    DragLog.log(
                        "fitting: \(window.bundleID) went below its recorded floor"
                            + " — now \(Int(floor))pt \(axis.rawValue)")
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
        in windows: [WindowFitting.Window], screen: NSScreen
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
        // nothing, not a constraint the app expressed. Recording it would
        // make the app read as unshrinkable forever and push the fitter
        // toward evicting instead of resizing.
        if learned.minimum >= axis.extent(screen.frame) * 0.8 {
            DragLog.log(
                "fitting: ignoring implausible \(learned.bundleID) floor of "
                    + "\(Int(learned.minimum))pt \(axis.rawValue)")
            return
        }
        // Another window of the same app, currently smaller than this refusal
        // claims, is proof the refusal was the tree's doing and not the app's.
        let floor = WindowFitting.corroborated(
            learned.minimum, forBundleID: learned.bundleID, among: windows, axis: axis)
        if floor < learned.minimum {
            DragLog.log(
                "fitting: \(learned.bundleID) refused at \(Int(learned.minimum))pt "
                    + "\(axis.rawValue) but another of its windows sits at "
                    + "\(Int(floor))pt — recording that instead")
        } else {
            DragLog.log(
                "fitting: learned \(learned.bundleID) won't go below "
                    + "\(Int(floor))pt \(axis.rawValue)")
        }
        minimums.record(bundleID: learned.bundleID, axis: axis, minimum: floor)
        minimums.save()
    }

    /// Is this window filling the display? A little tolerance, since a
    /// fullscreen frame can sit a point or two inside the screen rect.
    private func covers(_ frame: CGRect, _ display: CGRect) -> Bool {
        frame.width >= display.width * 0.98 && frame.height >= display.height * 0.95
    }

    /// The region AeroSpace actually tiles into on `screen`, in CGWindowList's
    /// top-left coordinates. A window pushed past this edge overlaps nothing
    /// and is still plainly broken.
    ///
    /// Not the whole screen. AeroSpace insets the workspace by the outer
    /// gaps, and by the bar's reserved space at the bottom — so a window can
    /// be pushed below the tiled area, still be on screen, and be plainly
    /// wrong while a screen-sized bounds check calls it fine. That's exactly
    /// the "partially outside the tiled area" case a vertical resize leaves
    /// behind.
    private func displayBounds(_ config: PanewrightConfig, screen: NSScreen) -> CGRect? {
        let outer = CGFloat(config.gaps.outer)
        // The emitter adds the bar's reserved height to whichever edge the
        // bar lives on — mirror that rather than re-deriving it. The bar
        // draws on every display, so the reserve applies on every screen.
        let reserve =
            config.statusBar.enabled
            ? CGFloat(SketchyBarConfigEmitter.reservedGap(for: config.statusBar)) : 0
        let barAtBottom = config.statusBar.position == .bottom
        let bottom = outer + (barAtBottom ? reserve : 0)
        let extraTop = barAtBottom ? 0 : reserve
        // visibleFrame is the screen minus what the system has already
        // claimed: the menu bar, and the Dock on whichever edge it happens to
        // live. It is the only way to be right for all four placements —
        // there is no "where is the Dock" API, and its thickness moves with
        // the tile size and magnification setting anyway.
        //
        // Using the full frame here meant this believed it had 1728 points of
        // a 1728pt display while AeroSpace was tiling into 1679 of it,
        // because AeroSpace does respect the Dock. Every deficit was
        // under-measured by the width of the Dock, and every "but the display
        // is Npt" in the log named a display that wasn't there.
        let full = screen.frame
        let visible = screen.visibleFrame
        let insetLeft = visible.minX - full.minX
        let insetRight = full.maxX - visible.maxX
        // AppKit measures from the bottom-left, CGWindowList from the
        // top-left, and every frame compared against these bounds comes from
        // the latter. The y flip also has to account for the screen's own
        // origin: only the primary display starts at zero in either system.
        let insetTop = full.maxY - visible.maxY
        let insetBottom = visible.minY - full.minY
        return CGRect(
            x: full.minX + insetLeft + outer,
            y: (Monitors.primaryTop - full.maxY) + insetTop + outer + extraTop,
            width: full.width - insetLeft - insetRight - outer * 2,
            height: full.height - insetTop - insetBottom - outer - extraTop - bottom)
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

    /// Move the newest arrival out, and always say so. A window vanishing
    /// from a workspace with no explanation reads as a bug, not a feature.
    private func evict(
        id: UInt32, windows: [WindowFitting.Window], entry: Monitors.VisibleWorkspace,
        state: WorkspaceState, cli: AeroSpaceCLI
    ) {
        // Confirm it's still here, from AeroSpace rather than from our cache.
        // The cache only refreshes when the on-screen window set changes, so
        // it can still list a window that has already been moved away — and
        // moving it "again" lands it on the workspace it's already on.
        if let listing = try? cli.run([
            "list-windows", "--workspace", entry.workspace, "--format", "%{window-id}",
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
        // An empty workspace on the same monitor, so the window stays on the
        // display the user is working on — i3 keeps outputs independent, and
        // an eviction that teleports a window to another physical screen
        // reads as losing it twice.
        guard let destination = firstEmptyWorkspace(cli: cli, monitorID: entry.monitorID)
        else {
            DragLog.log("fitting: nothing fits but there's no empty workspace to use")
            state.settled = signature(of: windows)
            return
        }
        let name = appName(for: id, windows: windows)
        do {
            try cli.run([
                "move-node-to-workspace", "--window-id", "\(id)", destination,
            ])
            state.lastEviction = Date()
            // Wait for the window set to actually change before considering
            // another. Evicting removes a window, which frees space for the
            // ones left — deciding again off geometry that hasn't re-tiled is
            // how one necessary eviction became two, on a workspace that fit
            // perfectly well once the first window had gone.
            state.evictedFrom = Set(windows.map(\.id))
            state.recentlyEvicted[id] = Date()
            // Keep this from growing across a long session.
            state.recentlyEvicted = state.recentlyEvicted.filter {
                Date().timeIntervalSince($0.value) < Self.reEvictionGuard * 2
            }
            // On screen for a moment, and the reasoning in the log.
            //
            // A system notification is the wrong weight: it persists in
            // Notification Center and asks to be dismissed, for something
            // that stops being relevant the moment it's read. The arithmetic
            // that justified the move is worth keeping, but in the log rather
            // than in your face — the toast only has to answer "where did my
            // window go".
            Toast.show("\(name) moved to workspace \(destination) — it wouldn't fit")
            if let config = try? Orchestrator().loadConfig(),
                let bounds = displayBounds(config, screen: entry.screen)
            {
                let capacity = WindowFitting.capacity(
                    of: windows, minimums: minimums.minimums, bounds: bounds,
                    separation: CGFloat(config.gaps.inner))
                if !capacity.explanation.isEmpty {
                    DragLog.log("fitting: \(capacity.explanation)")
                }
            }
            DragLog.log("fitting: evicted \(name) (\(id)) to workspace \(destination)")
            reset(state)
        } catch {
            DragLog.log("fitting: eviction failed: \(error)")
            state.settled = signature(of: windows)
        }
    }

    /// A floating window covered by a tiled one defeats the point of floating
    /// it. Only ever acts when that's actually happening, so it can't fight
    /// the user for control of their own stacking. Judged across all visible
    /// workspaces at once: raising is per-window and CGWindowList is global.
    private func raiseFloaters(
        onScreen: [OnScreenWindow], among visible: [Monitors.VisibleWorkspace]
    ) {
        var floating: Set<UInt32> = []
        var tiled: Set<UInt32> = []
        for entry in visible {
            guard let state = states[entry.workspace] else { continue }
            floating.formUnion(state.cachedFloating)
            floating.formUnion(state.fullscreenIDs)
            tiled.formUnion(Set(state.cachedBundleIDs.keys).subtracting(state.fullscreenIDs))
        }
        guard !floating.isEmpty else { return }
        let raised = FloatingWindowRaiser.raiseOccludedFloaters(
            onScreen: onScreen, floating: floating, tiled: tiled)
        if !raised.isEmpty {
            DragLog.log("fitting: raised floating window(s) \(raised) above the tiling")
        }
    }

    // MARK: Reading the world

    /// The visible-workspace roster, re-fetched only when the on-screen
    /// window set changes or the cache ages out — same economics as the
    /// per-workspace membership cache.
    private func visibleWorkspaces(
        cli: AeroSpaceCLI, onScreen: [OnScreenWindow]
    ) -> [Monitors.VisibleWorkspace] {
        let live = Set(onScreen.map(\.id))
        if live != visibleCacheIDs || Date().timeIntervalSince(visibleCachedAt) > 2 {
            visibleCache = Monitors.visibleWorkspaces(cli: cli)
            visibleCacheIDs = live
            visibleCachedAt = Date()
        }
        return visibleCache
    }

    private func currentWindows(
        cli: AeroSpaceCLI, workspace: String, screen: NSScreen, state: WorkspaceState,
        onScreen: [OnScreenWindow]? = nil
    ) -> [WindowFitting.Window] {
        let onScreen = onScreen ?? WindowSnapshot.capture(allLayers: true)
        let live = Set(onScreen.map(\.id))
        // Which windows are tiled here changes far more slowly than where
        // they are, so the answer is cached and only re-fetched when the set
        // of on-screen windows changes (or the cache ages out). That keeps
        // the polling loop down to one CGWindowList call, which is what makes
        // a sub-second cadence affordable.
        if live != state.cachedWindowIDs || Date().timeIntervalSince(state.cachedAt) > 2 {
            let listing = fetchWorkspace(cli: cli, workspace: workspace)
            state.cachedBundleIDs = listing.tiled
            state.cachedFloating = listing.floating
            state.cachedWindowIDs = live
            state.cachedAt = Date()
        }
        guard !state.cachedBundleIDs.isEmpty else { return [] }
        let now = Date()
        // The raw screen here, not the tiled area: this only rejects windows
        // parked far off-screen, and a window legitimately overlapping the
        // bar must still be seen so it can be corrected. Judged against the
        // workspace's own display — a window on a second monitor is exactly
        // as on-screen as one on the first.
        let visible = Monitors.cgFrame(of: screen)
        state.fullscreenIDs = []
        var windows: [WindowFitting.Window] = []
        for window in onScreen {
            guard let bundleID = state.cachedBundleIDs[window.id] else { continue }
            // AeroSpace hides windows by parking them far off-screen rather
            // than using Spaces, and a window parked in a bar pill is hidden
            // the same way. Mid-move, such a window can still be listed as
            // belonging to the focused workspace while its frame is nowhere
            // near the display — which reads as an enormous out-of-bounds
            // deficit that no resize can fix, so the only move left is to
            // evict it. That is what scattered real windows across workspaces
            // three times. A window with no pixels on the display isn't part
            // of the layout and has no business influencing it.
            if !window.frame.intersects(visible) { continue }
            // A window covering essentially the whole display isn't sharing
            // it with anyone, so it isn't tiling and must not be measured
            // against its neighbours.
            //
            // Judged on geometry rather than on AeroSpace's is-fullscreen
            // flag, which lags: for up to two seconds after the green button
            // the app is drawn fullscreen while still reported as tiled. In
            // that gap it looks like one window overlapping every other,
            // nothing can shrink to fix it, and the only move left is
            // eviction — which is exactly how full-screening an app kicked it
            // to the next workspace.
            if covers(window.frame, visible) {
                state.fullscreenIDs.insert(window.id)
                continue
            }
            let arrived = state.firstSeen[window.id] ?? now
            state.firstSeen[window.id] = arrived
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
    /// Only genuinely tiled windows are returned. A floating window isn't
    /// part of the layout — it's deliberately sitting on top of it — so
    /// counting it would have the fitter endlessly resizing the tiled windows
    /// underneath to get away from something that is supposed to overlap
    /// them. Fullscreen windows are excluded for the same reason: one covers
    /// everything, which reads as a collision with every window at once.
    private func fetchWorkspace(
        cli: AeroSpaceCLI, workspace: String
    ) -> (tiled: [UInt32: String], floating: Set<UInt32>) {
        guard
            let listing = try? cli.run([
                "list-windows", "--workspace", workspace,
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

    private func firstEmptyWorkspace(cli: AeroSpaceCLI, monitorID: Int) -> String? {
        guard
            let output = try? cli.run([
                "list-workspaces", "--monitor", "\(monitorID)", "--empty",
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

    private func reset(_ state: WorkspaceState) {
        state.consecutiveOverlaps = 0
        state.settled = nil
    }

    /// Drop remembered arrival times for windows that are gone — and tell the
    /// user's hooks who came and went. The fitter already watches every
    /// window on a sub-second tick, so open/close events are free to observe
    /// here and nowhere else.
    ///
    /// Scoped per workspace: comparing against a single global set meant a
    /// workspace *switch* looked like every old window closing and every new
    /// one opening. A window that genuinely moves between visible workspaces
    /// still reads as closed-here, opened-there — which is what happened.
    private func prune(
        to windows: [WindowFitting.Window], state: WorkspaceState, config: PanewrightConfig
    ) {
        let live = Set(windows.map(\.id))
        let known = Set(state.lastKnown.keys)
        // No dispatch on the very first pass: launching Panewright over an
        // existing desktop is not thirty windows "opening".
        if !known.isEmpty {
            if let hook = config.windowOpenedHook {
                for window in windows where !known.contains(window.id) {
                    Self.runHook(hook, window: window)
                }
            }
            if let hook = config.windowClosedHook {
                for id in known.subtracting(live) {
                    guard let record = state.lastKnown[id] else { continue }
                    Self.runHook(hook, window: record)
                }
            }
        }
        for window in windows { state.lastKnown[window.id] = window }
        state.lastKnown = state.lastKnown.filter { live.contains($0.key) }
        state.firstSeen = state.firstSeen.filter { live.contains($0.key) }
    }

    /// User hooks run detached with the window's identity in the environment,
    /// mirroring the engine-side hooks (WORKSPACE, FOCUSED_* etc.).
    private static func runHook(_ hook: String, window: WindowFitting.Window) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", hook]
        var env = ProcessInfo.processInfo.environment
        env["WINDOW_ID"] = "\(window.id)"
        env["APP_BUNDLE_ID"] = window.bundleID
        env["APP_NAME"] = window.bundleID.split(separator: ".").last.map(String.init) ?? ""
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        try? process.run()
    }
}
