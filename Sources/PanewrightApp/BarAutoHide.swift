import AppKit
import PanewrightCore

/// The optional auto-hiding bar: hidden until the pointer touches its screen
/// edge, hidden again a configurable delay after the pointer leaves. Tiles
/// reclaim the strip the bar normally reserves (reservedGap goes to zero),
/// so hiding buys real screen space, not just a cleaner look.
///
/// Polling the pointer, not tapping events: NSEvent.mouseLocation needs no
/// permission and no tap, and five reads a second of a static property is
/// cheaper than the cheapest event monitor. The fitter set the precedent.
@MainActor
final class BarAutoHide {
    private var timer: Timer?
    private var revealed = false
    private var pointerLeftAt: Date?
    /// The edge strip that summons the bar — deliberately thin, so ordinary
    /// work near the bottom of a window doesn't flash the bar.
    private static let summonBand: CGFloat = 3

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let config = try? Orchestrator().loadConfig(),
            config.statusBar.enabled, config.statusBar.autoHide,
            let bar = SketchyBarSupervisor.locate(), bar.isRunning(),
            let screen = NSScreen.main
        else {
            // Auto-hide switched off while revealed: leave the bar shown and
            // forget our state, so toggling the feature never strands a
            // hidden bar.
            if revealed || pointerLeftAt != nil {
                revealed = false
                pointerLeftAt = nil
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        // The bar's own band (bottom or top of the screen, its thickness
        // plus the summon strip) — pointer inside means "keep it shown".
        let barBand = CGFloat(config.statusBar.effectiveThickness) + 12
        let inBand: Bool
        if config.statusBar.position == .bottom {
            inBand = mouse.y <= (revealed ? barBand : Self.summonBand)
        } else {
            let top = screen.frame.maxY
            inBand = mouse.y >= top - (revealed ? barBand : Self.summonBand)
        }
        if inBand {
            pointerLeftAt = nil
            if !revealed {
                revealed = true
                try? bar.setHidden(false)
            }
            return
        }
        guard revealed else { return }
        if pointerLeftAt == nil { pointerLeftAt = Date() }
        if Date().timeIntervalSince(pointerLeftAt!) >= config.statusBar.autoHideDelay {
            revealed = false
            pointerLeftAt = nil
            try? bar.setHidden(true)
        }
    }
}
