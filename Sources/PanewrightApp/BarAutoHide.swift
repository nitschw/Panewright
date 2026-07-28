import AppKit
import PanewrightCore

/// The optional auto-hiding bar: slides off its screen edge, slides back
/// when the pointer touches that edge, and slides away again a configurable
/// delay after the pointer leaves. Tiles reclaim the strip the bar normally
/// reserves (reservedGap goes to zero), so hiding buys real screen space.
///
/// Slides, not `hidden=on`: the binary toggle is instantaneous, which reads
/// as the bar vanishing; the animator makes it leave.
///
/// Polling the pointer, not tapping events: NSEvent.mouseLocation needs no
/// permission and no tap, and five reads a second of a static property is
/// cheaper than the cheapest event monitor. The fitter set the precedent.
@MainActor
final class BarAutoHide {
    private var timer: Timer?
    private var revealed = false
    private var pointerLeftAt: Date?
    /// The feature's state last tick, so flipping it on reveals-then-times
    /// -out instead of yanking the bar away mid-thought, and flipping it off
    /// always leaves the bar shown.
    private var wasEnabled: Bool?
    /// The edge strip that summons the bar — deliberately thin, so ordinary
    /// work near the bottom of a window doesn't flash the bar.
    private static let summonBand: CGFloat = 6

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
    }

    private func tick() {
        // No process is spawned on this five-per-second path. It used to
        // pgrep for the bar before even checking whether auto-hide was on —
        // five main-thread spawns per second, forever, for everyone. On
        // machines whose endpoint security taxes each spawn that saturated
        // the main thread outright: the app "froze and stayed frozen" while
        // every sample showed waitUntilExit under this timer. The bar's
        // liveness is the health check's job; a slide command sent to a dead
        // bar fails silently and costs nothing.
        guard let config = try? Orchestrator().loadConfig(),
            let bar = SketchyBarSupervisor.locate()
        else { return }
        let enabled = config.statusBar.enabled && config.statusBar.autoHide
        defer { wasEnabled = enabled }
        guard enabled else {
            // Flipped off (or never on): make sure the bar is at its normal
            // offset, once, so disabling never strands a slid-away bar.
            if wasEnabled == true {
                DragLog.log("autohide: disabled — sliding the bar home")
                try? bar.animateBarOffset(revealOffset(config))
                revealed = false
                pointerLeftAt = nil
            }
            return
        }
        // Just flipped on: show the bar and let the timer take it away, so
        // the user sees the feature do its thing instead of losing the bar
        // the instant they click the toggle.
        if wasEnabled != true {
            DragLog.log("autohide: enabled — revealed, hiding in \(Int(config.statusBar.autoHideDelay))s")
            try? bar.animateBarOffset(revealOffset(config))
            revealed = true
            pointerLeftAt = Date()
            return
        }
        let mouse = NSEvent.mouseLocation
        // The bar draws (and hides) on every display, so the summoning edge
        // is the edge of whichever screen the pointer is on — measured from
        // that screen's own bottom or top, which is only zero on the primary.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        else { return }
        let barBand = CGFloat(config.statusBar.effectiveThickness) + 14
        let inBand: Bool
        if config.statusBar.position == .bottom {
            inBand = mouse.y <= screen.frame.minY + (revealed ? barBand : Self.summonBand)
        } else {
            let top = screen.frame.maxY
            inBand = mouse.y >= top - (revealed ? barBand : Self.summonBand)
        }
        if inBand {
            pointerLeftAt = nil
            if !revealed {
                revealed = true
                DragLog.log("autohide: pointer at the edge — sliding in")
                try? bar.animateBarOffset(revealOffset(config))
            }
            return
        }
        guard revealed else { return }
        if pointerLeftAt == nil { pointerLeftAt = Date() }
        if Date().timeIntervalSince(pointerLeftAt!) >= config.statusBar.autoHideDelay {
            revealed = false
            pointerLeftAt = nil
            DragLog.log("autohide: sliding away")
            try? bar.animateBarOffset(
                SketchyBarConfigEmitter.hiddenOffset(for: config.statusBar))
        }
    }

    /// The bar's shown position, dock lift included — the same numbers the
    /// emitted config uses, from the same function.
    private func revealOffset(_ config: PanewrightConfig) -> Int {
        SketchyBarConfigEmitter.barGeometry(
            for: config.statusBar.theme,
            dockInsetBottom: DockInset.bottom, dockInsetSides: DockInset.sides
        ).yOffset
    }
}
