import AppKit
import CoreGraphics
import PanewrightCore

/// Writes the SketchyBar-display → AeroSpace-monitor mapping the bar plugins
/// read. The two number monitors independently (SketchyBar by Quartz display
/// order, AeroSpace by its own arrangement), so per-monitor workspace strips
/// need a geometry-derived bridge, refreshed whenever displays change.
@MainActor
enum MonitorMap {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/panewright/monitor-map.tsv")

    /// AeroSpace monitor id of macOS's main display (the one owning the menu
    /// bar), matched by name — so distribution can pile the "rest" workspaces
    /// on the display the user thinks of as primary, not whichever AeroSpace
    /// happened to number first.
    static func mainMonitorID() -> Int? {
        guard let name = screenName(for: CGMainDisplayID()) else { return nil }
        return monitorsByName()[normalize(name)]
    }

    private static func monitorsByName() -> [String: Int] {
        guard let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run(["list-monitors"])
        else { return [:] }
        var monitorByName: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: " | ")
            if parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                monitorByName[normalize(parts[1])] = id
            }
        }
        return monitorByName
    }

    /// Returns true when the map file's content actually changed — the
    /// caller's cue to reload the bar. Reloading on every write attempt
    /// meant a plug/unplug rebuilt the bar three or four times (each one
    /// visible), when the map only changed once.
    @discardableResult
    static func write() -> Bool {
        let monitorByName = monitorsByName()
        guard !monitorByName.isEmpty else { return false }

        // Active displays in Quartz order = SketchyBar's display-1..N.
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }

        // SketchyBar does NOT number displays in CGGetActiveDisplayList order,
        // so binding "display-N" to the N-th active display swaps monitors.
        // Instead, ask SketchyBar where each of its displays actually sits (the
        // CG origin it reports for a bar-wide item) and match that point to the
        // physical display that contains it — geometry, not list order.
        let displayOrigins = sketchyBarDisplayOrigins()
        var entries: [(sketchyDisplay: Int, monitor: Int, displayID: CGDirectDisplayID)] = []
        if !displayOrigins.isEmpty {
            for (sketchyDisplay, origin) in displayOrigins {
                guard
                    let displayID = ids.first(where: { CGDisplayBounds($0).contains(origin) }),
                    let name = screenName(for: displayID),
                    let monitor = monitorByName[normalize(name)]
                else { continue }
                entries.append((sketchyDisplay, monitor, displayID))
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            // The bar is mid-reload (all rects are off-screen sentinels), but a
            // previous geometry-derived map exists. Keep it: a stale-but-right
            // map beats overwriting with the guessed list order, which briefly
            // misroutes every bar click and drag (the map was observed flapping
            // wrong→right on every display event). The caller's retry loop is
            // what eventually replaces it — this branch returning silently,
            // with nothing scheduled to try again, is how a two-display setup
            // ran for hours on a one-display map and the M-badges never
            // appeared.
            DragLog.log("monitor-map: bar mid-reload — keeping previous map for now")
            return false
        } else {
            // No bar and no map yet (first boot): fall back to list order;
            // observe() rewrites the map once the bar is up.
            for (index, displayID) in ids.enumerated() {
                guard let name = screenName(for: displayID),
                    let monitor = monitorByName[normalize(name)]
                else { continue }
                entries.append((index + 1, monitor, displayID))
            }
        }

        // Human-facing monitor numbers: the primary (macOS main display) is
        // always M1; the rest count up left-to-right by position. Stable and
        // predictable, unlike AeroSpace's internal ids.
        let main = CGMainDisplayID()
        let ordered = entries.sorted {
            if ($0.displayID == main) != ($1.displayID == main) { return $0.displayID == main }
            return CGDisplayBounds($0.displayID).minX < CGDisplayBounds($1.displayID).minX
        }
        var labelByDisplay: [Int: Int] = [:]
        for (index, entry) in ordered.enumerated() {
            labelByDisplay[entry.sketchyDisplay] = index + 1
        }

        let lines = entries
            .map { "\($0.sketchyDisplay)\t\($0.monitor)\t\(labelByDisplay[$0.sketchyDisplay] ?? $0.monitor)" }
            .sorted()
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        guard content != (try? String(contentsOf: url, encoding: .utf8)) else { return false }
        DragLog.log("monitor-map: \(lines.joined(separator: " "))")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// SketchyBar display index → the CG origin it reports for a full-bar item
    /// (`front_app`, present on every display). The origin lands inside that
    /// display's `CGDisplayBounds`, so it pins each SketchyBar display to a
    /// physical one regardless of how SketchyBar orders them.
    nonisolated static func sketchyBarDisplayOrigins() -> [Int: CGPoint] {
        let process = Process()
        process.executableURL = URL(filePath: "/opt/homebrew/bin/sketchybar")
        process.arguments = ["--query", "front_app"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [:] }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let json = try? JSONSerialization.jsonObject(
                with: pipe.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
            let rects = json["bounding_rects"] as? [String: Any]
        else { return [:] }

        var origins: [Int: CGPoint] = [:]
        for (key, value) in rects {
            guard let index = Int(key.replacingOccurrences(of: "display-", with: "")),
                let rect = value as? [String: Any],
                let origin = rect["origin"] as? [Double], origin.count == 2,
                origin[0] > -9000, origin[1] > -9000  // skip off-screen sentinels
            else { continue }
            origins[index] = CGPoint(x: origin[0], y: origin[1])
        }
        return origins
    }

    /// Fingerprint of the physical display arrangement. macOS posts
    /// didChangeScreenParametersNotification for far more than plug/unplug —
    /// activating an app is enough — and reacting to those false alarms
    /// reloads the bar (visible flicker) and re-spreads workspaces. Only a
    /// changed fingerprint counts as a real display change.
    private static var displayFingerprint = ""

    private static func currentFingerprint() -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "" }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "" }
        return ids.map { "\($0):\(CGDisplayBounds($0))" }.joined(separator: "|")
    }

    /// How long the display arrangement must hold still before it's believed.
    ///
    /// Docking is not one event: the log shows the same external display
    /// connecting and disconnecting six times in fifty seconds while the
    /// link negotiated. Reacting to each flap reloaded the bar (visible
    /// flicker) and re-spread workspaces (windows visibly teleporting) once
    /// per flap — the arrangement that finally settled had been "handled"
    /// six times. Nothing here is urgent enough to be wrong about.
    private static let settleDelay: Duration = .seconds(4)
    private static var pendingChange: Task<Void, Never>?

    /// When the display arrangement last visibly changed — health checks
    /// consult this to hold recovery actions during a docking storm, when
    /// monitors renumber several times a second and anything "recovered"
    /// mid-storm is recovered onto geography that's about to change again.
    private(set) static var lastDisplayEvent = Date.distantPast

    /// Rewrite the map and repaint the bar whenever the display layout changes.
    /// Plugging or unplugging a monitor also re-spreads workspaces so the new
    /// display gets one (and an unplugged one's workspaces return home).
    private static var observing = false

    static func observe() {
        // Once: a second registration means a second display handler racing
        // the first through redistribute on every display event.
        if observing {
            refreshMap()
            redistribute()
            return
        }
        observing = true
        displayFingerprint = currentFingerprint()
        refreshMap()
        // Initial spread: bootstrap left AeroSpace settled but with everything
        // piled on the primary, so distribute once now that we know the true
        // main display.
        redistribute()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let fingerprint = currentFingerprint()
                guard fingerprint != displayFingerprint else { return }
                DragLog.log("display change: \(fingerprint) — settling")
                displayFingerprint = fingerprint
                lastDisplayEvent = Date()
                // Coalesce the storm: each change restarts the clock, and
                // only the arrangement that survives the quiet period gets
                // acted on.
                pendingChange?.cancel()
                pendingChange = Task { @MainActor in
                    try? await Task.sleep(for: settleDelay)
                    guard !Task.isCancelled else { return }
                    DragLog.log("display change settled: \(currentFingerprint())")
                    refreshMap()
                    redistribute()
                    AppDelegate.model?.displaySettled()
                }
            }
        }
    }

    /// Seed the map immediately (may fall back to list order for the first
    /// paint), then off-thread wait for the bar to actually position its items
    /// and rewrite the map from real SketchyBar geometry. The first write can't
    /// use geometry because SketchyBar reports off-screen sentinels until it has
    /// laid the bar out, and blocking the main thread to wait would freeze the
    /// UI.
    /// The engine relaunched: its monitor ids renumbered, so the map —
    /// and everything reading it — must be rebuilt even though no physical
    /// display changed. Same treatment as a display change.
    static func engineRelaunched() {
        refreshMap()
        redistribute()
    }

    /// A map whose engine ids no longer match `list-monitors` paints
    /// M-badges with no workspace pills under them (the strip queries
    /// monitors that don't exist). Cheap to detect; called from the health
    /// tick so a stale map can never outlive one.
    nonisolated static func refreshIfStale() async {
        // The list-monitors spawn stays off the main actor: this runs every
        // 20 seconds, and a taxed spawn on main was part of a rhythmic
        // beachball.
        let current = Set(Self.monitorIDsByNameOffMain().values)
        guard !current.isEmpty else { return }
        let mapURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/panewright/monitor-map.tsv")
        let mapped = Set(
            ((try? String(contentsOf: mapURL, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .compactMap { line -> Int? in
                    let parts = line.split(separator: "\t")
                    return parts.count >= 2 ? Int(parts[1]) : nil
                })
        guard !mapped.isEmpty, mapped != current else { return }
        await MainActor.run {
            DragLog.log(
                "monitor-map: engine ids changed \(mapped.sorted()) → \(current.sorted()) — rebuilding")
            engineRelaunched()
        }
    }

    /// Same as monitorsByName, callable off the main actor.
    nonisolated private static func monitorIDsByNameOffMain() -> [String: Int] {
        guard let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run(["list-monitors"])
        else { return [:] }
        var monitorByName: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: " | ")
            if parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                monitorByName[parts[1].trimmingCharacters(in: .whitespaces).lowercased()] = id
            }
        }
        return monitorByName
    }

    private static func refreshMap() {
        if write() { reloadBar() }
        Task.detached(priority: .userInitiated) {
            // Wait for the bar to report geometry for *every* display, not
            // just any: right after a display change SketchyBar answers for
            // the displays it has laid out so far, and a map written from a
            // partial answer is exactly as wrong as the stale one. The
            // generous window matters — during a dock's link negotiation the
            // bar can be mid-reload for a long time, and giving up early is
            // how the map stayed at one display until the next reboot.
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            let displays = Int(count)
            var complete = false
            for _ in 0..<75 {
                if sketchyBarDisplayOrigins().count >= displays {
                    complete = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            if !complete {
                DragLog.log(
                    "monitor-map: bar never reported all \(displays) display(s)"
                        + " — writing what it has")
            }
            let reloaded = await MainActor.run { () -> Bool in
                if write() {
                    reloadBar()
                    return true
                }
                return false
            }
            // A reload rebuilds every item from the rc, forgetting their
            // per-display assignments; give it a beat to lay out, then hand
            // each display its bar personality. No reload, no wait.
            if reloaded { try? await Task.sleep(for: .seconds(3)) }
            if let config = try? Orchestrator().loadConfig() {
                await BarProfiles.apply(config)
            }
        }
    }

    /// Re-spread workspaces across the current displays (off the main thread,
    /// since it shells out to AeroSpace), then repaint the bar.
    /// AeroSpace monitor ids in M-label order — primary first, then left to
    /// right by position — so the ordinal distribution (ws0→M1, ws1→M2…)
    /// agrees with the numbers painted on the bar.
    private static func orderedMonitorIDs() -> [Int] {
        let byName = monitorsByName()
        guard !byName.isEmpty else { return [] }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.sorted {
            if ($0 == main) != ($1 == main) { return $0 == main }
            return CGDisplayBounds($0).minX < CGDisplayBounds($1).minX
        }
        .compactMap { screenName(for: $0).flatMap { byName[normalize($0)] } }
    }

    private static func redistribute() {
        let primary = mainMonitorID()
        let ordered = orderedMonitorIDs()
        Task.detached(priority: .userInitiated) {
            Orchestrator().distributeWorkspaces(
                primaryMonitorID: primary, orderedMonitorIDs: ordered)
            await MainActor.run {
                if write() { reloadBar() }
            }
        }
    }

    private static func reloadBar() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "/opt/homebrew/bin/sketchybar --reload 2>/dev/null"]
        try? process.run()
    }

    private static func screenName(for displayID: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }?.localizedName
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
