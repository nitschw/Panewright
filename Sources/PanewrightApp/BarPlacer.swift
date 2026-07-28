import AppKit
import CoreGraphics
import PanewrightCore

/// Puts the bar's bottom edge where it belongs — by measuring, not by trusting
/// the units.
///
/// SketchyBar's `y_offset` does not move the bar by `y_offset` points. On this
/// display it moves it by exactly twice that (measured at offsets 0, 5, 30 and
/// 52: displacement was 0, 10, 60 and 104), while `margin` is honest 1:1.
/// Whether the factor is the Retina scale, the notch, or a SketchyBar quirk is
/// unknowable from here and liable to differ per machine — so no factor is
/// hardcoded anywhere. The bar's real frame from CGWindowList is ground truth,
/// same as it is for the window fitter: ask for a position, measure what
/// happened, correct once with the ratio the measurement just revealed.
///
/// The bill for skipping this was a bar computed to float above the Dock that
/// actually sat 44 points up inside the tiled area, under the windows.
@MainActor
enum BarPlacer {
    /// How far above the Dock (or the raw screen edge) the bar floats — the
    /// theme's own base offset, from the same function the emitted config
    /// uses, so the measured placement and the config can't disagree. (A
    /// hardcoded 5 here would also have nudged the technical theme's flush
    /// bar upward forever, since its base is 0.)
    private static func float(for bar: PanewrightConfig.StatusBar) -> CGFloat {
        CGFloat(SketchyBarConfigEmitter.barGeometry(for: bar.theme).yOffset)
    }
    /// Close enough. Fractional frames and pixel alignment make exact
    /// equality unreachable.
    private static let tolerance: CGFloat = 3

    /// Move the bar so its bottom sits `float` above the Dock. No-op when the
    /// bar is already there, so this is safe to call on every suspicion —
    /// screen-parameter notifications fire for app activations too, and a
    /// measure-first design makes false alarms free.
    static func reconcile() {
        // The measured placement exists for the bottom edge, where the Dock
        // and the bar can collide. A top bar has no Dock to dodge (the Dock
        // can't live there) and keeps its static offset.
        guard let config = try? Orchestrator().loadConfig(),
            config.statusBar.position != .top,
            // A hidden (auto-hide) bar has no measurable frame; the static
            // offset serves until it's revealed.
            !config.statusBar.autoHide,
            let bar = SketchyBarSupervisor.locate(), bar.isRunning(),
            let screen = NSScreen.main
        else { return }
        let rawBottom = screen.frame.height
        let target = CGFloat(DockInset.bottom) + float(for: config.statusBar)
        guard let measured = barBottomInset(rawBottom: rawBottom) else { return }
        if abs(measured.inset - target) <= tolerance { return }
        // One proportional correction. Displacement is linear in y_offset
        // (verified across four offsets), so a single measurement of the
        // current ratio pins the answer; a second pass only runs if the
        // measurement was taken mid-animation and lied.
        let ratio =
            measured.offset > 0 && measured.inset > 0
            ? measured.inset / measured.offset : 1
        let corrected = Int((target / max(ratio, 0.5)).rounded())
        DragLog.log(
            "bar: bottom inset is \(Int(measured.inset))pt, want \(Int(target))"
                + " — y_offset \(Int(measured.offset)) → \(corrected)"
                + " (unit ratio \(String(format: "%.2f", ratio)))")
        // Remember the display's unit ratio so the next emit seeds the
        // correct offset and the bar is BORN in place — relearning this
        // every boot meant a visible position jump seconds after launch,
        // every single startup, forever.
        SketchyBarConfigEmitter.rememberUnitRatio(max(ratio, 0.5))
        try? bar.setBarGeometry(yOffset: corrected)
    }

    /// The bar's real bottom inset from the raw screen bottom, plus the
    /// y_offset it was achieved with — both needed to learn the units.
    private static func barBottomInset(
        rawBottom: CGFloat
    ) -> (inset: CGFloat, offset: CGFloat)? {
        guard let bar = SketchyBarSupervisor.locate(),
            let offset = bar.queryBarYOffset()
        else { return nil }
        guard
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in list {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                owner.lowercased().contains("sketchybar"),
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], width > 800,
                let y = bounds["Y"], let height = bounds["Height"]
            else { continue }
            return (inset: rawBottom - (y + height), offset: CGFloat(offset))
        }
        return nil
    }
}
