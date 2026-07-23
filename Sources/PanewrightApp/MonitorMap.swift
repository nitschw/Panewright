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

        var lines: [String] = []
        for (index, displayID) in ids.enumerated() {
            guard let name = screenName(for: displayID),
                let monitor = monitorByName[normalize(name)]
            else { continue }
            lines.append("\(index + 1)\t\(monitor)")
        }
        DragLog.log("monitor-map: \(lines.joined(separator: " "))")
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rewrite the map and repaint the bar whenever the display layout changes.
    /// Plugging or unplugging a monitor also re-spreads workspaces so the new
    /// display gets one (and an unplugged one's workspaces return home).
    static func observe() {
        write()
        reloadBar()
        // Initial spread: bootstrap left AeroSpace settled but with everything
        // piled on the primary, so distribute once now that we know the true
        // main display.
        redistribute()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                write()
                redistribute()
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
