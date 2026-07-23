import AppKit
import CoreGraphics
import PanewrightCore

/// Drag-to-tile: watches for a tiled window being dragged by its title bar,
/// suppresses AeroSpace's native drag-swap by floating the window for the
/// drag's duration, previews the drop with an overlay, and realizes the drop
/// on release.
///
/// Needs Input Monitoring permission for the (listen-only) event tap.
@MainActor
final class DragTileController {
    private enum Phase {
        case idle
        /// Mouse went down in a title-bar band; waiting to cross the drag threshold.
        case armed(windowID: CGWindowID, start: CGPoint)
        case dragging(windowID: CGWindowID)
    }

    private static let titleBarHeight: CGFloat = 40
    private static let dragThreshold: CGFloat = 15

    private var phase = Phase.idle
    private var tap: CFMachPort?
    private let overlay = DropOverlayWindow()
    private var dropTarget: (window: OnScreenWindow, zone: DropZone)?
    var onStatus: (@Sendable (String) -> Void)?

    static var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system prompt / System Settings deep link.
    static func requestPermission() {
        CGRequestListenEventAccess()
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
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    if let refcon {
                        let controller = Unmanaged<DragTileController>
                            .fromOpaque(refcon).takeUnretainedValue()
                        // The tap's run loop source lives on the main run loop.
                        MainActor.assumeIsolated {
                            controller.handle(type: type, event: event)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            DragLog.log("start: tapCreate FAILED (permission not effective for this process?)")
            return false
        }
        DragLog.log("start: tap created and enabled")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        let point = event.location
        switch type {
        case .leftMouseDown:
            phase = .idle
            if let window = WindowSnapshot.topmost(at: point),
                point.y - window.frame.minY <= Self.titleBarHeight {
                DragLog.log("armed: window=\(window.id) at=\(point)")
                phase = .armed(windowID: window.id, start: point)
            }
        case .leftMouseDragged:
            switch phase {
            case .armed(let windowID, let start):
                if hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold {
                    beginDrag(windowID: windowID)
                }
            case .dragging(let windowID):
                updateDrag(windowID: windowID, at: point)
            case .idle:
                break
            }
        case .leftMouseUp:
            if case .dragging(let windowID) = phase {
                finishDrag(windowID: windowID)
            }
            phase = .idle
        default:
            break
        }
    }

    private func beginDrag(windowID: CGWindowID) {
        phase = .idle
        guard let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-windows", "--workspace", "focused",
                "--format", "%{window-id} %{window-layout}",
            ])
        else {
            return
        }
        let isTiled = output.split(separator: "\n").contains { line in
            let parts = line.split(separator: " ")
            return parts.count >= 2 && parts[0] == "\(windowID)"
                && parts[1].hasSuffix("tiles")
        }
        DragLog.log("beginDrag: window=\(windowID) tiled=\(isTiled)")
        guard isTiled else { return }
        // Float for the duration of the drag so AeroSpace's hardcoded
        // overlap-swap never fires; the drop executor re-tiles.
        do {
            try cli.run(["layout", "--window-id", "\(windowID)", "floating"])
            DragLog.log("beginDrag: floated \(windowID), dragging")
        } catch {
            DragLog.log("beginDrag: float FAILED: \(error)")
            return
        }
        phase = .dragging(windowID: windowID)
    }

    private func updateDrag(windowID: CGWindowID, at point: CGPoint) {
        guard
            let target = WindowSnapshot.topmost(at: point, excluding: [windowID]),
            let zone = DropZone.zone(at: point, in: target.frame)
        else {
            dropTarget = nil
            overlay.hide()
            return
        }
        if dropTarget?.window.id != target.id || dropTarget?.zone != zone {
            DragLog.log("target: window=\(target.id) zone=\(zone.rawValue)")
        }
        dropTarget = (target, zone)
        overlay.show(cgFrame: zone.previewFrame(in: target.frame))
    }

    private func finishDrag(windowID: CGWindowID) {
        overlay.hide()
        let target = dropTarget
        dropTarget = nil
        guard let cli = AeroSpaceCLI.locate() else { return }
        let onStatus = onStatus
        let executorTarget = target.map { ($0.window.id, $0.window.frame, $0.zone) }
        DragLog.log("drop: window=\(windowID) target=\(String(describing: executorTarget?.0)) zone=\(executorTarget?.2.rawValue ?? "none")")
        Task.detached(priority: .userInitiated) {
            let executor = DropExecutor(cli: cli)
            let message = executor.execute(dragged: windowID, target: executorTarget)
            DragLog.log("drop result: \(message)")
            onStatus?(message)
        }
    }
}
