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
        // A fullscreen window can't be tiled or rehomed — it owns its own
        // space. Drop out of fullscreen for the move, then restore it after.
        let wasFullscreen = isFullscreen(dragged)
        if wasFullscreen {
            DragLog.log("executor: leaving fullscreen to move window \(dragged)")
            try? cli.run(["fullscreen", "off", "--window-id", "\(dragged)"])
            usleep(Self.settleMicroseconds)
        }
        defer {
            if wasFullscreen {
                try? cli.run(["fullscreen", "on", "--window-id", "\(dragged)"])
            }
        }
        // Cross-monitor drop: the walk moves by swaps, which never leave a
        // workspace — so first rehome the dragged window into the target's
        // workspace, then treat it like any local drop.
        if let sourceWS = workspace(of: dragged), let targetWS = workspace(of: target.id),
            sourceWS != targetWS {
            DragLog.log("executor: cross-workspace drop \(sourceWS) -> \(targetWS)")
            guard
                (try? cli.run([
                    "move-node-to-workspace", "--window-id", "\(dragged)", targetWS,
                ])) != nil
            else {
                return "drag-to-tile: couldn't move to workspace \(targetWS)"
            }
            usleep(Self.settleMicroseconds)
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

    /// Fullscreen windows own an exclusive space, so tiling operations and
    /// cross-monitor moves silently do nothing until they leave it.
    private func isFullscreen(_ windowID: CGWindowID) -> Bool {
        guard
            let output = try? cli.run([
                "list-windows", "--all", "--format", "%{window-id} %{window-is-fullscreen}",
            ])
        else { return false }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, CGWindowID(parts[0]) == windowID {
                return parts[1].trimmingCharacters(in: .whitespaces) == "true"
            }
        }
        return false
    }

    private func workspace(of windowID: CGWindowID) -> String? {
        guard
            let output = try? cli.run([
                "list-windows", "--all", "--format", "%{window-id} %{workspace}",
            ])
        else { return nil }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, CGWindowID(parts[0]) == windowID {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

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
            // The tree shape matters here and isn't visible from the frames:
            // joining two windows that are the only children of a container
            // flips that container, but joining inside a deeper nest can
            // leave the orientation untouched. Record what we were acting on
            // so a drop that lands wrong can be diagnosed from the log.
            DragLog.log(
                "executor: join-with \(toward) to form horizontal pair"
                    + " — \(containerShape(dragged: dragged, target: targetID))")
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
        DragLog.log(
            "executor: settled — \(containerShape(dragged: dragged, target: targetID))")
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
            DragLog.log(
                "executor: join-with \(toward) to form vertical pair"
                    + " — \(containerShape(dragged: dragged, target: targetID))")
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
        DragLog.log(
            "executor: settled — \(containerShape(dragged: dragged, target: targetID))")
        return "drag-to-tile: stacked \(zone.rawValue) of target"
    }

    /// The parent container layout of both windows, which is what decides
    /// whether a join changes anything. Diagnostic only — never branched on,
    /// so a failure to read it can't change what the drop does.
    private func containerShape(dragged: CGWindowID, target: CGWindowID) -> String {
        guard
            let listing = try? cli.run([
                "list-windows", "--workspace", "focused",
                "--format", "%{window-id}|%{window-parent-container-layout}",
            ])
        else { return "shape unknown" }
        var shapes: [CGWindowID: String] = [:]
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2, let id = CGWindowID(parts[0]) else { continue }
            shapes[id] = parts[1]
        }
        return "dragged in \(shapes[dragged] ?? "?"), target in \(shapes[target] ?? "?")"
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
