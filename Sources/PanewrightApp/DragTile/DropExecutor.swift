import CoreGraphics
import Foundation
import PanewrightCore

/// Realizes a drop by walking the dragged window through AeroSpace's tree
/// with window-id-addressed commands. Heuristic v1: frames are re-read
/// between steps because AX layout settles asynchronously.
struct DropExecutor: Sendable {
    let cli: AeroSpaceCLI
    private static let settleMicroseconds: UInt32 = 150_000
    private static let maxSteps = 8

    /// `target` is nil when the drop landed on no window: just re-tile.
    func execute(
        dragged: CGWindowID,
        target: (id: CGWindowID, frame: CGRect, zone: DropZone)?
    ) -> String {
        // The drag floated the window (to suppress AeroSpace's native swap);
        // bring it back into the tree.
        guard (try? cli.run(["layout", "--window-id", "\(dragged)", "tiling"])) != nil else {
            return "drag-to-tile: could not re-tile the dragged window"
        }
        guard let target else {
            return "drag-to-tile: re-tiled (no drop target)"
        }
        switch target.zone {
        case .center:
            return swapWalk(dragged: dragged, targetID: target.id, targetFrame: target.frame)
        case .left, .right, .top, .bottom:
            return place(
                dragged: dragged, targetID: target.id, zone: target.zone)
        }
    }

    /// Center drop: swap-step toward the target until the dragged window
    /// occupies the target's original frame.
    private func swapWalk(
        dragged: CGWindowID, targetID: CGWindowID, targetFrame: CGRect
    ) -> String {
        for _ in 0..<Self.maxSteps {
            usleep(Self.settleMicroseconds)
            guard let dFrame = WindowSnapshot.frame(of: dragged) else {
                return "drag-to-tile: lost the dragged window"
            }
            if targetFrame.contains(CGPoint(x: dFrame.midX, y: dFrame.midY)) {
                return "drag-to-tile: swapped"
            }
            guard let tFrame = WindowSnapshot.frame(of: targetID) else {
                return "drag-to-tile: lost the target window"
            }
            let direction = Self.dominantDirection(from: dFrame, to: tFrame)
            guard (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) != nil else {
                return "drag-to-tile: swap toward \(direction) failed"
            }
        }
        return "drag-to-tile: gave up walking to the target"
    }

    /// Edge drop: get adjacent to the target, then either sit as its sibling
    /// on the chosen side (same-axis) or join into a nested stack (cross-axis).
    private func place(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone
    ) -> String {
        for _ in 0..<Self.maxSteps {
            usleep(Self.settleMicroseconds)
            guard let dFrame = WindowSnapshot.frame(of: dragged),
                let tFrame = WindowSnapshot.frame(of: targetID)
            else {
                return "drag-to-tile: lost a window mid-placement"
            }
            if Self.adjacent(dFrame, tFrame) {
                return finalize(
                    dragged: dragged, targetID: targetID, zone: zone,
                    dFrame: dFrame, tFrame: tFrame)
            }
            let direction = Self.dominantDirection(from: dFrame, to: tFrame)
            guard (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) != nil else {
                return "drag-to-tile: swap toward \(direction) failed"
            }
        }
        return "drag-to-tile: gave up walking to the target"
    }

    private func finalize(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone,
        dFrame: CGRect, tFrame: CGRect
    ) -> String {
        switch zone {
        case .left, .right:
            // Same-axis: be the sibling on the requested side.
            let draggedOnLeft = dFrame.midX < tFrame.midX
            if (zone == .left) != draggedOnLeft {
                let direction = zone == .left ? "left" : "right"
                try? cli.run(["swap", "--window-id", "\(dragged)", direction])
            }
            return "drag-to-tile: placed \(zone.rawValue) of target"
        case .top, .bottom:
            // Cross-axis: nest with the target, then order within the stack.
            let toward = Self.dominantDirection(from: dFrame, to: tFrame)
            guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil
            else {
                return "drag-to-tile: join-with \(toward) failed"
            }
            usleep(Self.settleMicroseconds)
            if let d = WindowSnapshot.frame(of: dragged),
                let t = WindowSnapshot.frame(of: targetID) {
                let draggedOnTop = d.midY < t.midY
                if (zone == .top) != draggedOnTop {
                    let direction = zone == .top ? "up" : "down"
                    try? cli.run(["move", "--window-id", "\(dragged)", direction])
                }
            }
            return "drag-to-tile: stacked \(zone.rawValue) of target"
        case .center:
            return "drag-to-tile: unexpected center in finalize"
        }
    }

    /// CG coordinates: +y is down, so "up" means decreasing y.
    static func dominantDirection(from: CGRect, to: CGRect) -> String {
        let dx = to.midX - from.midX
        let dy = to.midY - from.midY
        if abs(dx) >= abs(dy) {
            return dx < 0 ? "left" : "right"
        }
        return dy < 0 ? "up" : "down"
    }

    static func adjacent(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 30) -> Bool {
        let xTouch =
            abs(a.maxX - b.minX) <= tolerance || abs(b.maxX - a.minX) <= tolerance
        let yTouch =
            abs(a.maxY - b.minY) <= tolerance || abs(b.maxY - a.minY) <= tolerance
        let xOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
        let yOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0
        return (xTouch && yOverlap) || (yTouch && xOverlap)
    }
}
