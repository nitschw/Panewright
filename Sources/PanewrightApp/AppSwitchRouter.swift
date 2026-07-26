import AppKit
import Foundation
import PanewrightCore

/// Makes switching to an application land you where its window actually is.
///
/// Hooks application activation rather than Cmd+Tab itself. macOS's switcher
/// is perfectly good and reimplementing it would be a large, fragile job for
/// no benefit — and hooking activation means this works identically for the
/// Dock, Spotlight, Raycast, and anything else that raises an app.
@MainActor
final class AppSwitchRouter {
    private var observer: NSObjectProtocol?
    /// Set while we're acting on our own decision.
    ///
    /// Summoning a pill or focusing a window raises that app, which posts
    /// another activation notification. Without this the router would answer
    /// its own move and could ping-pong between two workspaces.
    private var actingUntil = Date.distantPast

    func start() {
        stop()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.handle(app) }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private func handle(_ app: NSRunningApplication?) {
        guard Date() >= actingUntil,
            let bundleID = app?.bundleIdentifier,
            // Our own windows are settings and panels, not tiled content.
            bundleID != Bundle.main.bundleIdentifier,
            let config = try? Orchestrator().loadConfig(), config.followAppSwitch,
            let cli = AeroSpaceCLI.locate()
        else { return }

        guard let focused = try? cli.run(["list-workspaces", "--focused"]).trimmed(),
            !focused.isEmpty
        else { return }
        let windows = knownWindows(cli: cli)
        switch AppSwitchRouting.route(to: bundleID, windows: windows, focusedWorkspace: focused) {
        case .nothing:
            return
        case .summonPill(let id):
            // Reuse the same script the pill's own click runs, so a summon
            // from Cmd+Tab and a summon from the bar behave identically and
            // there's one place to fix if that behaviour changes.
            actingUntil = Date().addingTimeInterval(1.5)
            runScript("pill-toggle.sh", id: id)
            DragLog.log("switch: summoned parked \(bundleID)")
        case .focusWindow(let id):
            actingUntil = Date().addingTimeInterval(1.5)
            try? cli.run(["focus", "--window-id", "\(id)"])
            DragLog.log("switch: followed \(bundleID) to its workspace")
        }
    }

    private func knownWindows(cli: AeroSpaceCLI) -> [AppSwitchRouting.Window] {
        guard
            let listing = try? cli.run([
                "list-windows", "--all",
                "--format", "%{window-id}|%{app-bundle-id}|%{workspace}",
            ])
        else { return [] }
        return listing.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 3, let id = UInt32(parts[0]) else { return nil }
            return AppSwitchRouting.Window(id: id, bundleID: parts[1], workspace: parts[2])
        }
    }

    private func runScript(_ name: String, id: UInt32) {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/panewright/scripts/\(name)")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path, "\(id)"]
        try? process.run()
    }
}

extension String {
    fileprivate func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
