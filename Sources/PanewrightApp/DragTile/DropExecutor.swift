import CoreGraphics
import Foundation
import PanewrightCore

/// Realizes a ghost drop by walking the dragged window through AeroSpace's
/// tree with window-id swaps, then finishing with the zone's operation.
/// Navigation is axis-aware: close the unaligned axis first, require a real
/// shared edge before treating windows as neighbors, and log every step.
struct DropExecutor: Sendable {
    let cli: AeroSpaceCLI
    private static let settleMicroseconds: UInt32 = 180_000
    private static let maxSteps = 8

    func execute(
        dragged: CGWindowID,
        target: (id: CGWindowID, frame: CGRect, zone: DropZone)?
    ) -> String {
        guard let target else {
            return "drag-to-tile: canceled"
        }
        switch target.zone {
        case .center:
            return swap(dragged: dragged, targetID: target.id)
        case .left, .right:
            return placeBeside(dragged: dragged, targetID: target.id, zone: target.zone)
        case .top, .bottom:
            return stack(dragged: dragged, targetID: target.id, zone: target.zone)
        }
    }

    // MARK: Zone operations

    private func swap(dragged: CGWindowID, targetID: CGWindowID) -> String {
        guard
            let (d, t) = walk(dragged: dragged, targetID: targetID, until: { d, t in
                Self.adjacentHorizontally(d, t) || Self.adjacentVertically(d, t)
            })
        else {
            return "drag-to-tile: couldn't reach the target to swap"
        }
        let direction =
            Self.adjacentHorizontally(d, t)
            ? Self.horizontalDirection(from: d, to: t)
            : Self.verticalDirection(from: d, to: t)
        guard (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) != nil else {
            return "drag-to-tile: final swap \(direction) failed"
        }
        return "drag-to-tile: swapped with target"
    }

    private func placeBeside(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone
    ) -> String {
        guard
            let (d, t) = walk(dragged: dragged, targetID: targetID, until: {
                Self.adjacentHorizontally($0, $1)
            })
        else {
            return "drag-to-tile: couldn't reach the target"
        }
        // Horizontally adjacent with a real shared edge ⇒ the neighbor in
        // that direction is the target; one more swap crosses to the far side.
        let draggedOnLeft = d.midX < t.midX
        if (zone == .left) != draggedOnLeft {
            let direction = Self.horizontalDirection(from: d, to: t)
            guard (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) != nil
            else {
                return "drag-to-tile: side-crossing swap failed"
            }
        }
        return "drag-to-tile: placed \(zone.rawValue) of target"
    }

    private func stack(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone
    ) -> String {
        guard
            let (d, t) = walk(dragged: dragged, targetID: targetID, until: {
                Self.adjacentHorizontally($0, $1)
            })
        else {
            return "drag-to-tile: couldn't reach the target"
        }
        let toward = Self.horizontalDirection(from: d, to: t)
        guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil else {
            return "drag-to-tile: join-with \(toward) failed"
        }
        usleep(Self.settleMicroseconds)
        if let newD = WindowSnapshot.frame(of: dragged),
            let newT = WindowSnapshot.frame(of: targetID) {
            let draggedOnTop = newD.midY < newT.midY
            if (zone == .top) != draggedOnTop {
                let direction = zone == .top ? "up" : "down"
                try? cli.run(["move", "--window-id", "\(dragged)", direction])
            }
        }
        return "drag-to-tile: stacked \(zone.rawValue) of target"
    }

    // MARK: Walking

    private func walk(
        dragged: CGWindowID, targetID: CGWindowID,
        until isDone: (CGRect, CGRect) -> Bool
    ) -> (CGRect, CGRect)? {
        for step in 0..<Self.maxSteps {
            usleep(Self.settleMicroseconds)
            guard let d = WindowSnapshot.frame(of: dragged),
                let t = WindowSnapshot.frame(of: targetID)
            else {
                DragLog.log("executor: lost a window at step \(step)")
                return nil
            }
            if isDone(d, t) {
                return (d, t)
            }
            let direction = Self.step(from: d, to: t)
            DragLog.log("executor step \(step): swap \(direction) d=\(d) t=\(t)")
            if (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) == nil {
                // Dead end (no neighbor that way) — try the other axis once.
                let fallback =
                    (direction == "left" || direction == "right")
                    ? Self.verticalDirection(from: d, to: t)
                    : Self.horizontalDirection(from: d, to: t)
                DragLog.log("executor step \(step): dead end, fallback \(fallback)")
                if (try? cli.run(["swap", "--window-id", "\(dragged)", fallback])) == nil {
                    return nil
                }
            }
        }
        DragLog.log("executor: gave up after \(Self.maxSteps) steps")
        return nil
    }

    /// Axis-aware step: if the windows share a column band, close the vertical
    /// distance; a row band, horizontal; diagonal, the larger gap first.
    static func step(from d: CGRect, to t: CGRect) -> String {
        let xOverlap = overlap(d.minX, d.maxX, t.minX, t.maxX)
        let yOverlap = overlap(d.minY, d.maxY, t.minY, t.maxY)
        if xOverlap <= 0 && yOverlap <= 0 {
            let xGap = max(t.minX - d.maxX, d.minX - t.maxX)
            let yGap = max(t.minY - d.maxY, d.minY - t.maxY)
            return xGap >= yGap
                ? horizontalDirection(from: d, to: t)
                : verticalDirection(from: d, to: t)
        }
        return xOverlap > 0
            ? verticalDirection(from: d, to: t)
            : horizontalDirection(from: d, to: t)
    }

    // MARK: Geometry

    static func overlap(
        _ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat
    ) -> CGFloat {
        min(aMax, bMax) - max(aMin, bMin)
    }

    /// Sharing a vertical edge: x-gap within tolerance and at least half the
    /// smaller window's height in common — a real neighbor, not a corner graze.
    static func adjacentHorizontally(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 30) -> Bool {
        let touch = abs(a.maxX - b.minX) <= tolerance || abs(b.maxX - a.minX) <= tolerance
        return touch
            && overlap(a.minY, a.maxY, b.minY, b.maxY) > min(a.height, b.height) / 2
    }

    static func adjacentVertically(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 30) -> Bool {
        let touch = abs(a.maxY - b.minY) <= tolerance || abs(b.maxY - a.minY) <= tolerance
        return touch
            && overlap(a.minX, a.maxX, b.minX, b.maxX) > min(a.width, b.width) / 2
    }

    /// CG coordinates: +y is down, so "up" means decreasing y.
    static func horizontalDirection(from: CGRect, to: CGRect) -> String {
        to.midX < from.midX ? "left" : "right"
    }

    static func verticalDirection(from: CGRect, to: CGRect) -> String {
        to.midY < from.midY ? "up" : "down"
    }
}
