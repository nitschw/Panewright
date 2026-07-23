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
    private var runLoopSource: CFRunLoopSource?
    private let sourceOverlay = DropOverlayWindow(style: .source)
    private let targetOverlay = DropOverlayWindow(style: .target)
    private enum DropDestination {
        case window(OnScreenWindow, DropZone)
        /// A workspace number item on the status bar.
        case workspace(Int)
        /// Empty space on the bar — park the window as a pill.
        case parkAsPill
    }

    private var destination: DropDestination?
    /// Screen rects of the bar's workspace numbers across *all* displays.
    private var workspaceZones: [(number: Int, frame: CGRect)] = []
    /// One bar strip per display — dropping in any of them (away from a
    /// workspace number) parks the window as a pill. Per-display, not a
    /// union, so negative-origin monitors are handled correctly.
    private var barBands: [CGRect] = []
    private(set) var dragToBarEnabled = true

    func configure(dragToBar: Bool) {
        dragToBarEnabled = dragToBar
    }
    var onStatus: (@Sendable (String) -> Void)?

    // Focus-follows-mouse (opt-in via config).
    private(set) var focusFollowsMouse = false
    private var lastHoverFocus: CGWindowID?
    private var lastHoverCheck: CFTimeInterval = 0
    /// Every window AeroSpace manages on the focused workspace — tiled *and*
    /// floating. Hover focus picks the topmost of these, so floating panels
    /// (which often live above the normal window layer) can be reached.
    private var managedWindows: Set<CGWindowID> = []
    private var managedRefreshedAt: CFTimeInterval = 0
    /// The focused workspace's tiled windows, refreshed off the main thread.
    /// The event-tap callback must never spawn a subprocess — a modifying
    /// tap that blocks freezes ALL system input — so `arm` reads this cache.
    private var cachedTiledIDs: Set<CGWindowID> = []
    private var tiledRefresh: DispatchSourceTimer?

    /// The tap's event mask is fixed at creation, so changing the option
    /// rebuilds the tap.
    func configure(focusFollowsMouse enabled: Bool) {
        guard enabled != focusFollowsMouse else { return }
        focusFollowsMouse = enabled
        if tap != nil {
            stopTap()
            _ = start()
        }
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tiledRefresh?.cancel()
        tiledRefresh = nil
        tap = nil
        runLoopSource = nil
    }

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
        var mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        if focusFollowsMouse {
            mask |= 1 << CGEventType.mouseMoved.rawValue
        }
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
        DragLog.log(
            "start: modifying tap created (focusFollowsMouse=\(focusFollowsMouse))")
        let screens = NSScreen.screens.map {
            "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))"
        }.joined(separator: " | ")
        DragLog.log("start: \(NSScreen.screens.count) screen(s): \(screens)")
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startTiledCacheRefresh()
        return true
    }

    /// Keep the tiled-window cache warm off the main thread, so the event
    /// callback stays subprocess-free.
    private func startTiledCacheRefresh() {
        guard tiledRefresh == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.5)
        // @Sendable so it isn't inferred MainActor-isolated (it's created in
        // a @MainActor method but must run on the utility queue).
        timer.setEventHandler { @Sendable [weak self] in
            guard let cli = AeroSpaceCLI.locate(),
                let output = try? cli.run([
                    "list-windows", "--workspace", "focused",
                    "--format", "%{window-id} %{window-layout}",
                ])
            else { return }
            var ids: Set<CGWindowID> = []
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let id = CGWindowID(parts[0]),
                    parts[1].hasSuffix("tiles") {
                    ids.insert(id)
                }
            }
            Task { @MainActor in self?.cachedTiledIDs = ids }
        }
        timer.resume()
        tiledRefresh = timer
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
        case .mouseMoved:
            hoverFocus(at: point)
            return false
        default:
            return false
        }
    }

    /// Focus follows mouse: throttled, off-main CLI call, never during drags.
    private func hoverFocus(at point: CGPoint) {
        guard focusFollowsMouse, case .idle = phase else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHoverCheck > 0.1 else { return }
        lastHoverCheck = now
        refreshManagedWindowsIfStale(now: now)
        // Front-to-back order, so the first hit is whatever is actually on
        // top under the pointer — including a floating window over a tile.
        let managed = managedWindows
        let candidates = WindowSnapshot.capture(allLayers: !managed.isEmpty)
        guard
            let window = candidates.first(where: {
                guard !Self.ignoredOwners.contains($0.ownerName),
                    $0.frame.contains(point)
                else { return false }
                return managed.isEmpty || managed.contains($0.id)
            }),
            window.id != lastHoverFocus
        else {
            return
        }
        lastHoverFocus = window.id
        guard let cli = AeroSpaceCLI.locate() else { return }
        let windowID = window.id
        Task.detached(priority: .utility) {
            try? cli.run(["focus", "--window-id", "\(windowID)"])
        }
    }

    private func arm(at point: CGPoint) {
        // Entirely synchronous and subprocess-free: CGWindowList (fast) plus
        // the off-thread tiled cache. Never call cli.run here — this runs
        // inside the modifying event tap, and blocking it freezes system
        // input.
        guard
            let window = WindowSnapshot.capture().first(where: {
                !Self.ignoredOwners.contains($0.ownerName) && $0.frame.contains(point)
            }),
            point.y - window.frame.minY <= Self.titleBarHeight
        else {
            return
        }
        var tiledIDs = cachedTiledIDs
        guard tiledIDs.contains(window.id) else { return }
        tiledIDs.remove(window.id)
        DragLog.log("armed: window=\(window.id) owner=\(window.ownerName)")
        phase = .armed(
            windowID: window.id, start: point, targets: tiledIDs, sourceFrame: window.frame)
        // Bar geometry can shift with workspaces/theme; refresh per drag.
        // (MainActor closure built here so `self` never crosses the
        // detachment boundary — Swift 6.0 compilers insist.)
        let assign: @MainActor @Sendable ([(number: Int, frame: CGRect)], [CGRect]) -> Void =
            { [weak self] zones, bands in
                self?.workspaceZones = zones
                self?.barBands = bands
            }
        Task.detached {
            let (zones, bands) = Self.queryBarGeometry()
            DragLog.log("arm: \(zones.count) workspace zone(s), \(bands.count) bar band(s)")
            await assign(zones, bands)
        }
    }

    private func refreshManagedWindowsIfStale(now: CFTimeInterval) {
        guard now - managedRefreshedAt > 2 else { return }
        managedRefreshedAt = now
        guard let cli = AeroSpaceCLI.locate() else { return }
        let assign: @MainActor @Sendable (Set<CGWindowID>) -> Void = { [weak self] ids in
            self?.managedWindows = ids
        }
        Task.detached(priority: .utility) {
            guard
                let output = try? cli.run([
                    "list-windows", "--workspace", "focused", "--format", "%{window-id}",
                ])
            else { return }
            let ids = Set(
                output.split(separator: "\n").compactMap {
                    CGWindowID($0.trimmingCharacters(in: .whitespaces))
                })
            await assign(ids)
        }
    }

    /// Asks SketchyBar where its workspace items are (empty if no bar).
    /// Workspace-number rects across every display, plus one bar strip per
    /// display. SketchyBar reports `bounding_rects` keyed by display, all in
    /// the same top-left-origin space as CGEvent locations — so a strip is
    /// built per display from that display's own pill y and its CG bounds.
    nonisolated private static func queryBarGeometry()
        -> (zones: [(number: Int, frame: CGRect)], bands: [CGRect])
    {
        let sketchybar = "/opt/homebrew/bin/sketchybar"
        guard FileManager.default.isExecutableFile(atPath: sketchybar) else { return ([], []) }
        let displayBounds = activeDisplayBounds()
        var zones: [(number: Int, frame: CGRect)] = []
        // display key → the pill strip's vertical extent on that display.
        var stripYByDisplay: [String: (minY: CGFloat, maxY: CGFloat)] = [:]

        for number in Array(1...9) + [0] {
            let process = Process()
            process.executableURL = URL(filePath: sketchybar)
            process.arguments = ["--query", "space.\(number)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                let json = try? JSONSerialization.jsonObject(
                    with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
                let rects = json["bounding_rects"] as? [String: Any]
            else { continue }
            for (displayKey, value) in rects {
                guard let rect = value as? [String: Any],
                    let origin = rect["origin"] as? [Double], origin.count == 2,
                    let size = rect["size"] as? [Double], size.count == 2
                else { continue }
                let frame = CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
                zones.append((number, frame))
                let existing = stripYByDisplay[displayKey]
                stripYByDisplay[displayKey] = (
                    min(existing?.minY ?? frame.minY, frame.minY),
                    max(existing?.maxY ?? frame.maxY, frame.maxY))
            }
        }

        // One band per display: full display width at that display's strip y.
        var bands: [CGRect] = []
        for (_, strip) in stripYByDisplay {
            let mid = CGPoint(x: 0, y: (strip.minY + strip.maxY) / 2)
            let bounds =
                displayBounds.first {
                    $0.minY <= strip.maxY && $0.maxY >= strip.minY
                        && $0.height > 0
                } ?? CGRect(x: mid.x, y: strip.minY, width: 3000, height: strip.maxY - strip.minY)
            bands.append(
                CGRect(
                    x: bounds.minX, y: strip.minY - 6,
                    width: bounds.width, height: (strip.maxY - strip.minY) + 12))
        }
        return (zones, bands)
    }

    /// Every active display's bounds in CG global (top-left origin) space —
    /// the same space as CGEvent locations and SketchyBar rects.
    nonisolated private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.map { CGDisplayBounds($0) }
    }

    private func updateDrag(windowID: CGWindowID, targets: Set<CGWindowID>, at point: CGPoint) {
        // Bar workspace numbers take priority — they're above any window.
        if let zone = workspaceZones.first(where: {
            $0.frame.insetBy(dx: -8, dy: -8).contains(point)
        }) {
            if case .workspace(zone.number) = destination {} else {
                DragLog.log("target: workspace item \(zone.number)")
            }
            destination = .workspace(zone.number)
            targetOverlay.show(cgFrame: zone.frame.insetBy(dx: -4, dy: -4))
            return
        }
        // Anywhere else on the bar parks the window as a pill.
        if dragToBarEnabled, let band = barBands.first(where: { $0.contains(point) }) {
            if case .parkAsPill = destination {} else {
                DragLog.log("target: bar (park as pill)")
            }
            destination = .parkAsPill
            targetOverlay.show(cgFrame: band)
            return
        }
        guard
            let target = WindowSnapshot.capture().first(where: {
                targets.contains($0.id) && $0.frame.contains(point)
            }),
            let zone = DropZone.zone(at: point, in: target.frame)
        else {
            destination = nil
            targetOverlay.hide()
            return
        }
        if case .window(let previous, let previousZone) = destination,
            previous.id == target.id, previousZone == zone {
        } else {
            DragLog.log("target: window=\(target.id) owner=\(target.ownerName) zone=\(zone.rawValue)")
        }
        destination = .window(target, zone)
        targetOverlay.show(cgFrame: zone.previewFrame(in: target.frame))
    }

    private func finishDrag(windowID: CGWindowID) {
        sourceOverlay.hide()
        targetOverlay.hide()
        let destination = destination
        self.destination = nil
        guard let cli = AeroSpaceCLI.locate() else { return }
        let onStatus = onStatus
        switch destination {
        case .workspace(let number):
            DragLog.log("drop: window=\(windowID) → workspace \(number)")
            Task.detached(priority: .userInitiated) {
                do {
                    try cli.run([
                        "move-node-to-workspace", "--window-id", "\(windowID)", "\(number)",
                    ])
                    DragLog.log("drop result: sent to workspace \(number)")
                    onStatus?("drag-to-tile: sent to workspace \(number)")
                } catch {
                    DragLog.log("drop result: workspace move failed: \(error)")
                    onStatus?("drag-to-tile: move to workspace \(number) failed")
                }
            }
        case .parkAsPill:
            DragLog.log("drop: window=\(windowID) → parked as pill")
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/bash")
                process.arguments = [
                    NSHomeDirectory() + "/.config/panewright/scripts/pill-window.sh",
                    "\(windowID)",
                ]
                try? process.run()
                process.waitUntilExit()
                onStatus?("parked in the bar")
            }
        case .window, .none:
            var executorTarget: (CGWindowID, CGRect, DropZone)?
            if case .window(let target, let zone) = destination {
                executorTarget = (target.id, target.frame, zone)
            }
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
}
