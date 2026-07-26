import AppKit

/// How much of a screen edge the system has already claimed.
///
/// There is no API that reports where the Dock is or how thick it is. macOS
/// answers the same question from the other side: `visibleFrame` is what is
/// left of the screen once the menu bar and the Dock have taken their share,
/// so the difference between it and `frame` is exactly the space they occupy.
/// That holds for all four Dock placements, and it tracks tile size,
/// magnification and hiding without any of those needing to be known about.
enum DockInset {
    /// Points the Dock occupies along the bottom edge, or zero if it lives on
    /// another edge or is hidden.
    ///
    /// SketchyBar pins the bar to the bottom of the *raw* screen and knows
    /// nothing about the Dock, so a bottom Dock sits directly on top of it.
    /// This is the lift needed to clear it; see `sides` for the other case.
    @MainActor static var bottom: Int {
        guard let screen = NSScreen.main else { return 0 }
        return max(0, Int((screen.visibleFrame.minY - screen.frame.minY).rounded()))
    }

    /// The larger of the two side insets — a Dock on the left or the right.
    ///
    /// The bar spans the full width of its edge, so a side Dock overlaps its
    /// end however tall the Dock is. SketchyBar's only horizontal lever is
    /// `margin`, which insets both ends equally, so a 50pt Dock on the left
    /// costs 50pt on the right too. Asymmetric would waste less, but there is
    /// no `margin_left`, and a bar that reaches under the Dock at one end
    /// looks broken in a way a slightly narrower centred bar does not.
    @MainActor static var sides: Int {
        guard let screen = NSScreen.main else { return 0 }
        let left = screen.visibleFrame.minX - screen.frame.minX
        let right = screen.frame.maxX - screen.visibleFrame.maxX
        return max(0, Int(max(left, right).rounded()))
    }
}
