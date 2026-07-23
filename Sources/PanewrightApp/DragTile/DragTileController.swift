import AppKit
import ApplicationServices
import CoreGraphics
import PanewrightCore

/// Ghost drag-to-tile: pressing a tiled window's title bar and dragging never
/// moves the real window. A red overlay marks the source cell, a blue overlay
/// previews the drop target, and releasing performs the tree operation. The
/// tree is untouched until the drop, so layouts never collapse mid-drag.
///
/// Freezing the real window means consuming mouse-drag events before the app
/// sees them — a modifying event tap, which requires Accessibility permission
/// (plus Input Monitoring).
@MainActor
final class DragTileController {
    private enum Phase {
        case idle
        /// Mouse down on a tiled window's title bar; drags are consumed
        /// (window frozen) until we know click vs drag.
        case armed(windowID: CGWindowID, start: CGPoint, targets: Set<CGWindowID>, sourceFrame: CGRect)
        case dragging(windowID: CGWindowID, targets: Set<CGWindowID>)
    }

    private static let titleBarHeight: CGFloat = 40
    private static let dragThreshold: CGFloat = 15

    /// Overlay/border/bar daemons whose windows must never arm or receive drags.
    private static let ignoredOwners: Set<String> = ["borders", "sketchybar"]

    private var phase = Phase.idle
    private var tap: CFMachPort?
    private let sourceOverlay = DropOverlayWindow(style: .source)
    private let targetOverlay = DropOverlayWindow(style: .target)
    private var dropTarget: (window: OnScreenWindow, zone: DropZone)?
    var onStatus: (@Sendable (String) -> Void)?

    static var hasPermission: Bool {
        CGPreflightListenEventAccess() && AXIsProcessTrusted()
    }

    static func requestPermission() {
        CGRequestListenEventAccess()
        // kAXTrustedCheckOptionPrompt's raw value; the C global isn't
        // concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    var isActive: Bool {
        tap != nil
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        DragLog.log("start: permission=\(Self.hasPermission)")
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else {
                        return Unmanaged.passUnretained(event)
                    }
                    let controller = Unmanaged<DragTileController>
                        .fromOpaque(refcon).takeUnretainedValue()
                    // The tap's run loop source lives on the main run loop.
                    let consume = MainActor.assumeIsolated {
                        controller.handle(type: type, event: event)
                    }
                    return consume ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DragLog.log("start: tapCreate FAILED (Accessibility not effective for this process?)")
            return false
        }
        DragLog.log("start: modifying tap created and enabled")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true when the event must be consumed (window stays frozen).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        let point = event.location
        switch type {
        case .leftMouseDown:
            phase = .idle
            arm(at: point)
            return false
        case .leftMouseDragged:
            switch phase {
            case .armed(let windowID, let start, let targets, let sourceFrame):
                if hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold {
                    DragLog.log("ghost drag begins: window=\(windowID)")
                    sourceOverlay.show(cgFrame: sourceFrame)
                    phase = .dragging(windowID: windowID, targets: targets)
                    updateDrag(windowID: windowID, targets: targets, at: point)
                }
                return true
            case .dragging(let windowID, let targets):
                updateDrag(windowID: windowID, targets: targets, at: point)
                return true
            case .idle:
                return false
            }
        case .leftMouseUp:
            if case .dragging(let windowID, _) = phase {
                finishDrag(windowID: windowID)
            }
            phase = .idle
            return false
        default:
            return false
        }
    }

    private func arm(at point: CGPoint) {
        guard
            let window = WindowSnapshot.capture().first(where: {
                !Self.ignoredOwners.contains($0.ownerName) && $0.frame.contains(point)
            }),
            point.y - window.frame.minY <= Self.titleBarHeight,
            let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-windows", "--workspace", "focused",
                "--format", "%{window-id} %{window-layout}",
            ])
        else {
            return
        }
        var tiledIDs: Set<CGWindowID> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, let id = CGWindowID(parts[0]), parts[1].hasSuffix("tiles") {
                tiledIDs.insert(id)
            }
        }
        guard tiledIDs.contains(window.id) else { return }
        tiledIDs.remove(window.id)
        DragLog.log("armed: window=\(window.id) owner=\(window.ownerName)")
        phase = .armed(
            windowID: window.id, start: point, targets: tiledIDs, sourceFrame: window.frame)
    }

    private func updateDrag(windowID: CGWindowID, targets: Set<CGWindowID>, at point: CGPoint) {
        guard
            let target = WindowSnapshot.capture().first(where: {
                targets.contains($0.id) && $0.frame.contains(point)
            }),
            let zone = DropZone.zone(at: point, in: target.frame)
        else {
            dropTarget = nil
            targetOverlay.hide()
            return
        }
        if dropTarget?.window.id != target.id || dropTarget?.zone != zone {
            DragLog.log("target: window=\(target.id) owner=\(target.ownerName) zone=\(zone.rawValue)")
        }
        dropTarget = (target, zone)
        targetOverlay.show(cgFrame: zone.previewFrame(in: target.frame))
    }

    private func finishDrag(windowID: CGWindowID) {
        sourceOverlay.hide()
        targetOverlay.hide()
        let target = dropTarget
        dropTarget = nil
        guard let cli = AeroSpaceCLI.locate() else { return }
        let onStatus = onStatus
        let executorTarget = target.map { ($0.window.id, $0.window.frame, $0.zone) }
        DragLog.log(
            "drop: window=\(windowID) target=\(String(describing: executorTarget?.0)) zone=\(executorTarget?.2.rawValue ?? "none")"
        )
        Task.detached(priority: .userInitiated) {
            let executor = DropExecutor(cli: cli)
            let message = executor.execute(dragged: windowID, target: executorTarget)
            DragLog.log("drop result: \(message)")
            onStatus?(message)
        }
    }
}
