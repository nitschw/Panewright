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

    static func write() {
        let monitorByName = monitorsByName()
        guard !monitorByName.isEmpty else { return }

        // Active displays in Quartz order = SketchyBar's display-1..N.
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

        // SketchyBar does NOT number displays in CGGetActiveDisplayList order,
        // so binding "display-N" to the N-th active display swaps monitors.
        // Instead, ask SketchyBar where each of its displays actually sits (the
        // CG origin it reports for a bar-wide item) and match that point to the
        // physical display that contains it — geometry, not list order.
        let displayOrigins = sketchyBarDisplayOrigins()
        var lines: [String] = []
        if !displayOrigins.isEmpty {
            for (sketchyDisplay, origin) in displayOrigins {
                guard
                    let displayID = ids.first(where: { CGDisplayBounds($0).contains(origin) }),
                    let name = screenName(for: displayID),
                    let monitor = monitorByName[normalize(name)]
                else { continue }
                lines.append("\(sketchyDisplay)\t\(monitor)")
            }
        } else {
            // No bar yet (first boot): fall back to list order; observe()
            // rewrites the map once the bar is up.
            for (index, displayID) in ids.enumerated() {
                guard let name = screenName(for: displayID),
                    let monitor = monitorByName[normalize(name)]
                else { continue }
                lines.append("\(index + 1)\t\(monitor)")
            }
        }
        lines.sort { $0 < $1 }
        DragLog.log("monitor-map: \(lines.joined(separator: " "))")
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// SketchyBar display index → the CG origin it reports for a full-bar item
    /// (`front_app`, present on every display). The origin lands inside that
    /// display's `CGDisplayBounds`, so it pins each SketchyBar display to a
    /// physical one regardless of how SketchyBar orders them.
    nonisolated private static func sketchyBarDisplayOrigins() -> [Int: CGPoint] {
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

    /// Rewrite the map and repaint the bar whenever the display layout changes.
    /// Plugging or unplugging a monitor also re-spreads workspaces so the new
    /// display gets one (and an unplugged one's workspaces return home).
    static func observe() {
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
                refreshMap()
                redistribute()
            }
        }
    }

    /// Seed the map immediately (may fall back to list order for the first
    /// paint), then off-thread wait for the bar to actually position its items
    /// and rewrite the map from real SketchyBar geometry. The first write can't
    /// use geometry because SketchyBar reports off-screen sentinels until it has
    /// laid the bar out, and blocking the main thread to wait would freeze the
    /// UI.
    private static func refreshMap() {
        write()
        reloadBar()
        Task.detached(priority: .userInitiated) {
            for _ in 0..<30 {
                if !sketchyBarDisplayOrigins().isEmpty { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            await MainActor.run {
                write()
                reloadBar()
            }
        }
    }

    /// Re-spread workspaces across the current displays (off the main thread,
    /// since it shells out to AeroSpace), then repaint the bar.
    private static func redistribute() {
        let primary = mainMonitorID()
        Task.detached(priority: .userInitiated) {
            Orchestrator().distributeWorkspaces(primaryMonitorID: primary)
            await MainActor.run {
                write()
                reloadBar()
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
