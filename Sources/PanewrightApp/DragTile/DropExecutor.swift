import CoreGraphics
import Foundation
import PanewrightCore

/// Realizes a ghost drop. Movement model: walk the dragged window through the
/// tree with window-id swaps until it genuinely neighbors the target, then
/// finish with the zone's operation. The key structural insight: placing
/// side-by-side windows that share a stack (or stacking windows that share a
/// row) is an orientation change, done with `join-with` — never with swaps.
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
        guard let (d, t) = walkToNeighbor(dragged: dragged, targetID: targetID) else {
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

    /// Left/right zones: end state is a horizontal pair. Same-stack neighbors
    /// get joined (orientation change); same-row neighbors just need the
    /// correct side.
    private func placeBeside(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone
    ) -> String {
        guard let (d, t) = walkToNeighbor(dragged: dragged, targetID: targetID) else {
            return "drag-to-tile: couldn't reach the target"
        }
        if Self.adjacentVertically(d, t) {
            let toward = Self.verticalDirection(from: d, to: t)
            DragLog.log("executor: join-with \(toward) to form horizontal pair")
            guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil
            else {
                return "drag-to-tile: join-with \(toward) failed"
            }
            usleep(Self.settleMicroseconds)
        }
        if let (d2, t2) = frames(dragged, targetID),
            (zone == .left) != (d2.midX < t2.midX) {
            let direction = Self.horizontalDirection(from: d2, to: t2)
            try? cli.run(["swap", "--window-id", "\(dragged)", direction])
        }
        return "drag-to-tile: placed \(zone.rawValue) of target"
    }

    /// Top/bottom zones: end state is a vertical pair — the mirror image.
    private func stack(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone
    ) -> String {
        guard let (d, t) = walkToNeighbor(dragged: dragged, targetID: targetID) else {
            return "drag-to-tile: couldn't reach the target"
        }
        if Self.adjacentHorizontally(d, t) {
            let toward = Self.horizontalDirection(from: d, to: t)
            DragLog.log("executor: join-with \(toward) to form vertical pair")
            guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil
            else {
                return "drag-to-tile: join-with \(toward) failed"
            }
            usleep(Self.settleMicroseconds)
        }
        if let (d2, t2) = frames(dragged, targetID),
            (zone == .top) != (d2.midY < t2.midY) {
            let direction = Self.verticalDirection(from: d2, to: t2)
            try? cli.run(["swap", "--window-id", "\(dragged)", direction])
        }
        return "drag-to-tile: stacked \(zone.rawValue) of target"
    }

    // MARK: Walking

    private func frames(_ a: CGWindowID, _ b: CGWindowID) -> (CGRect, CGRect)? {
        guard let fa = WindowSnapshot.frame(of: a), let fb = WindowSnapshot.frame(of: b)
        else {
            return nil
        }
        return (fa, fb)
    }

    /// Swap-steps the dragged window until it shares a real edge with the
    /// target on either axis. Aborts on revisited positions (oscillation).
    private func walkToNeighbor(
        dragged: CGWindowID, targetID: CGWindowID
    ) -> (CGRect, CGRect)? {
        var visited: [CGPoint] = []
        for step in 0..<Self.maxSteps {
            usleep(Self.settleMicroseconds)
            guard let (d, t) = frames(dragged, targetID) else {
                DragLog.log("executor: lost a window at step \(step)")
                return nil
            }
            if Self.adjacentHorizontally(d, t) || Self.adjacentVertically(d, t) {
                return (d, t)
            }
            if visited.contains(where: {
                abs($0.x - d.origin.x) < 2 && abs($0.y - d.origin.y) < 2
            }) {
                DragLog.log("executor: oscillation detected at step \(step), aborting")
                return nil
            }
            visited.append(d.origin)
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
