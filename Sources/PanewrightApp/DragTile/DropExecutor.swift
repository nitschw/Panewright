import AppKit
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
    /// Reshaping the tree settles more slowly than sliding windows around
    /// within it, and the reported container layout lags the frames by longer
    /// still — a `join-with` read back after a second still named the old
    /// parent. Only `containerShape` reads that field, and it is diagnostic
    /// only, but a log line that contradicts the screen costs an hour.
    private static let restructureMicroseconds: UInt32 = 350_000
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
            return place(
                dragged: dragged, targetID: target.id, zone: target.zone, axis: .horizontal)
        case .top, .bottom:
            return place(
                dragged: dragged, targetID: target.id, zone: target.zone, axis: .vertical)
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
            Self.neighbourAxis(d, t) == .horizontal
            ? Self.horizontalDirection(from: d, to: t)
            : Self.verticalDirection(from: d, to: t)
        guard (try? cli.run(["swap", "--window-id", "\(dragged)", direction])) != nil else {
            return "drag-to-tile: final swap \(direction) failed"
        }
        return "drag-to-tile: swapped with target"
    }

    /// Realize a drop as a pair along `axis`, dragged window on the side the
    /// zone names.
    ///
    /// One implementation for all four edge zones, because the two directions
    /// are the same operation with the coordinates swapped — and a bug proved
    /// it. Building a row out of a column failed in exactly the way building a
    /// column out of a row failed, one axis apart, because each direction had
    /// its own copy of this and only one of them could be fixed at a time.
    ///
    /// Three shapes the drop can start from, and the third was missing:
    ///
    /// 1. Neighbours on the *cross* axis — a row when a column is wanted. One
    ///    `join-with` flips the pair's orientation.
    /// 2. Neighbours on the right axis, already siblings. Nothing structural
    ///    to do; at most a swap to land on the requested side.
    /// 3. Neighbours on the right axis but *not* siblings. The dragged window
    ///    is touching the outside of the container the target lives in — a
    ///    full-height window beside a stacked pair, say. The frames look
    ///    finished, so this used to report success and do nothing at all.
    ///    It needs `move`, which descends into the neighbouring container
    ///    rather than swapping past it, and then a `join-with` to pair with
    ///    the target once they're at the same level.
    private func place(
        dragged: CGWindowID, targetID: CGWindowID, zone: DropZone,
        axis: WindowFitting.Axis
    ) -> String {
        guard let (d, t) = walkToNeighbor(dragged: dragged, targetID: targetID) else {
            return "drag-to-tile: couldn't reach the target"
        }
        // Neighbours on the cross axis *and* genuinely a pair: they must
        // span the same extent across that axis, which is what makes them
        // siblings rather than a window standing beside somebody else's
        // container. Without the second half, a full-height window next to a
        // stacked pair looked joinable — the join then paired the wrong two
        // nodes, reported success, and changed nothing.
        if Self.neighbourAxis(d, t) == axis.cross,
            WindowFitting.siblings(d, t, along: axis.cross)
        {
            let toward = Self.direction(from: d, to: t, along: axis.cross)
            // The tree shape matters here and isn't visible from the frames:
            // joining two windows that are the only children of a container
            // flips that container, but joining inside a deeper nest can
            // leave the orientation untouched. Record what we were acting on
            // so a drop that lands wrong can be diagnosed from the log.
            DragLog.log(
                "executor: join-with \(toward) to form \(axis) pair"
                    + " — \(containerShape(dragged: dragged, target: targetID))")
            guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil
            else {
                return "drag-to-tile: join-with \(toward) failed"
            }
            usleep(Self.restructureMicroseconds)
        } else if !WindowFitting.siblings(d, t, along: axis) {
            guard descend(dragged: dragged, targetID: targetID, axis: axis) else {
                return "drag-to-tile: couldn't join the target's container"
            }
        }
        // Whatever the route here, the pair now exists; only the order within
        // it might be wrong.
        let wantsLeading = zone == .left || zone == .top
        if let (d2, t2) = frames(dragged, targetID),
            wantsLeading != (axis.start(d2) < axis.start(t2)) {
            let direction = Self.direction(from: d2, to: t2, along: axis)
            try? cli.run(["swap", "--window-id", "\(dragged)", direction])
        }
        DragLog.log(
            "executor: settled — \(containerShape(dragged: dragged, target: targetID))")
        return axis == .horizontal
            ? "drag-to-tile: placed \(zone.rawValue) of target"
            : "drag-to-tile: stacked \(zone.rawValue) of target"
    }

    /// Move the dragged window into the container the target lives in, then
    /// pair the two.
    ///
    /// `move` is the primitive that makes this possible and `swap` is not:
    /// swapping exchanges two windows wherever they sit, so a window outside a
    /// nested container can swap with one inside it forever without ever
    /// getting in. `move` descends — given a neighbouring container it inserts
    /// the window into it rather than stepping over it.
    ///
    /// That lands the window in the target's container but stacked the wrong
    /// way (it joins the container's own axis), so the `join-with` afterwards
    /// pulls it alongside the target on the cross axis. Both directions are
    /// taken from freshly read frames rather than assumed, because where
    /// `move` inserts the window is AeroSpace's decision, not ours.
    private func descend(
        dragged: CGWindowID, targetID: CGWindowID, axis: WindowFitting.Axis
    ) -> Bool {
        guard let (d, t) = frames(dragged, targetID) else { return false }
        // Enter along the axis the two windows currently neighbour on — where
        // the container actually is — not along the axis the drop wants the
        // pair to end up on. Those coincide just often enough to be a trap: a
        // full-height window right of a stacked column descends correctly for
        // a left/right zone ("move left", toward the column) and used to walk
        // straight past it for a top/bottom zone ("move up", where there is
        // nothing but the workspace edge). The move then restructured
        // whatever it hit, the follow-up join had nothing to pair with, and
        // the drop failed after having already rearranged the tree.
        let entryAxis = Self.neighbourAxis(d, t) ?? axis
        let inward = Self.direction(from: d, to: t, along: entryAxis)
        DragLog.log(
            "executor: move \(inward) into the target's container"
                + " — \(containerShape(dragged: dragged, target: targetID))")
        guard (try? cli.run(["move", "--window-id", "\(dragged)", inward])) != nil else {
            return false
        }
        usleep(Self.restructureMicroseconds)
        guard let (d2, t2) = frames(dragged, targetID) else { return false }
        // The move often lands it as a proper sibling on its own — descending
        // into a column puts it in that column. Joining then has nothing in
        // the cross direction to join with, so AeroSpace exits non-zero and a
        // drop that had already worked was reported as a failure.
        if WindowFitting.siblings(d2, t2, along: axis) {
            DragLog.log("executor: the move alone produced the pair")
            return true
        }
        let toward = Self.direction(from: d2, to: t2, along: axis.cross)
        DragLog.log("executor: join-with \(toward) to pair inside the container")
        guard (try? cli.run(["join-with", "--window-id", "\(dragged)", toward])) != nil else {
            return false
        }
        usleep(Self.restructureMicroseconds)
        return true
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
        // Container labels alone proved misleading: a drop can end with both
        // windows reporting v_tiles and still not be stacked on screen. The
        // frames are the only thing that says whether it worked, so they go in
        // the log beside the labels.
        var geometry = ""
        if let (d, t) = frames(dragged, target) {
            geometry =
                " | dragged \(Int(d.minX)),\(Int(d.minY)) \(Int(d.width))x\(Int(d.height))"
                + " target \(Int(t.minX)),\(Int(t.minY)) \(Int(t.width))x\(Int(t.height))"
        }
        return "dragged in \(shapes[dragged] ?? "?"), target in \(shapes[target] ?? "?")"
            + geometry
    }

    // MARK: Walking

    private func frames(_ a: CGWindowID, _ b: CGWindowID) -> (CGRect, CGRect)? {
        // Directions computed from parked frames are noise, so wait out any
        // moment where the windows aren't actually on screen. AeroSpace parks
        // hidden workspaces' windows at the screen edge with a sliver left
        // visible, and the workspace can defocus *mid-drop*: activating the
        // dropped window's app can pull focus, and the app-switch follower or
        // focus-follows-mouse then swaps the whole workspace out under the
        // executor. Every window it was reasoning about teleports to the
        // parking corner between one read and the next — mid-diagnosis all
        // three repro windows measured x=1727 — and the same drop then
        // succeeds or fails depending on a race nobody can see.
        for attempt in 0...6 {
            guard let fa = WindowSnapshot.frame(of: a), let fb = WindowSnapshot.frame(of: b)
            else { return nil }
            if Self.onScreen(fa), Self.onScreen(fb) { return (fa, fb) }
            if attempt == 0 {
                DragLog.log("executor: windows are parked off-screen — waiting")
            }
            usleep(Self.restructureMicroseconds)
        }
        DragLog.log("executor: windows stayed parked — aborting rather than guessing")
        return nil
    }

    /// More of the window on screen than the one-point sliver parking leaves.
    private static func onScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            rect.intersection(screen.frame).width > 30
                && rect.intersection(screen.frame).height > 30
        }
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
            if Self.neighbourAxis(d, t) != nil {
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

    /// Which axis these two are laid out along, or nil if they aren't a pair.
    ///
    /// Deferred to ``WindowFitting/neighbouring(_:_:separation:tolerance:)``
    /// rather than measured here, because a drop and a fit have to agree about
    /// what "next to" means. They didn't: this asked whether the facing edges
    /// were within 30 points, using `abs`, so a side-by-side pair overlapping
    /// by 83 — the ordinary crowded workspace, and the reason someone reaches
    /// for a vertical stack in the first place — registered as neither
    /// horizontal nor vertical neighbours. The walk then swapped them back and
    /// forth until the oscillation guard gave up, and the drop did nothing.
    static func neighbourAxis(_ a: CGRect, _ b: CGRect) -> WindowFitting.Axis? {
        WindowFitting.neighbouring(a, b)
    }

    /// The AeroSpace direction word pointing from one frame toward another
    /// along `axis` — the only place a zone's axis turns back into a word.
    static func direction(
        from: CGRect, to: CGRect, along axis: WindowFitting.Axis
    ) -> String {
        axis == .horizontal
            ? horizontalDirection(from: from, to: to)
            : verticalDirection(from: from, to: to)
    }

    /// CG coordinates: +y is down, so "up" means decreasing y.
    static func horizontalDirection(from: CGRect, to: CGRect) -> String {
        to.midX < from.midX ? "left" : "right"
    }

    static func verticalDirection(from: CGRect, to: CGRect) -> String {
        to.midY < from.midY ? "up" : "down"
    }
}
