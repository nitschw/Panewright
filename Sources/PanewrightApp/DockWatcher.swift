import AppKit
import PanewrightCore

/// Keeps the bar clear of the Dock as the Dock moves.
///
/// The insets are measured at launch and whenever config is applied, which is
/// right up until the moment someone drags the Dock to another edge — then the
/// bar is positioned for a Dock that isn't there any more, either floating
/// over nothing or sitting underneath it.
///
/// Moving the Dock fires `didChangeScreenParametersNotification` because the
/// visible frame changed. `MonitorMap` hears the same notification and
/// deliberately ignores it — its fingerprint is built from `CGDisplayBounds`,
/// which the Dock does not affect — so this watcher is the Dock's only
/// listener, and the two cannot fight over one event.
///
/// The reaction is a live `--bar` push plus a quiet config rewrite, never an
/// `applyBar`: a reload tears down and repopulates every item, and a Dock
/// move is precisely the situation where the bar's contents didn't change.
@MainActor
final class DockWatcher {
    private var lastApplied: (bottom: Int, sides: Int)?
    private var debounce: Timer?

    private var observing = false

    func start() {
        // Reconcile immediately rather than recording the current insets as
        // "applied". The bar was configured with whatever the insets were at
        // bootstrap — and a Dock mid-drag at that moment measures as something
        // it never settles at. Seeding from the *current* insets buried that
        // mistake: nothing had "changed", so a bar positioned for a 61pt Dock
        // that ended up 47pt sat wrong indefinitely. Measure-first placement
        // makes this call free when the bar is already right.
        BarPlacer.reconcile()
        // The bar may still be laying itself out when the first pass runs (it
        // reports off-screen sentinels until it has) — one delayed retry
        // covers the launch race, and is free if the first pass landed.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { BarPlacer.reconcile() }
        }
        lastApplied = (DockInset.bottom, DockInset.sides)
        // Register the observer once; environment restarts call start()
        // again, and stacked observers meant stacked Dock reconciliations.
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
    }

    /// The system posts a burst of these while the Dock animates between
    /// edges; measuring mid-animation reads a half-moved Dock. One check after
    /// the burst goes quiet is both calmer and more accurate.
    private func scheduleCheck() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated { DockWatcher.check(self) }
        }
    }

    private static func check(_ watcher: DockWatcher) {
        let insets = (bottom: DockInset.bottom, sides: DockInset.sides)
        // Vertical placement is measured, so it self-corrects even when the
        // insets look unchanged (the change may have happened before the
        // watcher existed, or the last placement may have been made against a
        // mid-animation Dock).
        BarPlacer.reconcile()
        guard insets != watcher.lastApplied ?? (-1, -1) else { return }
        watcher.lastApplied = insets
        DragLog.log(
            "dock: moved — insets now bottom=\(insets.bottom) sides=\(insets.sides), "
                + "updating margin and config")
        let orchestrator = Orchestrator()
        guard let config = try? orchestrator.loadConfig() else { return }
        try? orchestrator.refreshBarGeometry(
            config, dockInsetBottom: insets.bottom, dockInsetSides: insets.sides)
    }
}
