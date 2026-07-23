import AppKit
import PanewrightCore
import ServiceManagement
import SwiftUI

@main
struct PanewrightApp: App {
    @State private var model = AppModel()

    init() {
        Self.terminateIfAlreadyRunning()
    }

    /// Bare-executable dev builds have no bundle ID for the usual
    /// single-instance check, so match on process name instead.
    private static func terminateIfAlreadyRunning() {
        let mine = ProcessInfo.processInfo.processIdentifier
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "panewright"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return }
        pgrep.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let others = output.split(separator: "\n")
            .compactMap { Int32($0) }
            .filter { $0 != mine }
        if !others.isEmpty {
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra("Panewright", systemImage: "rectangle.split.3x1") {
            PanewrightMenu(model: model)
        }
    }
}

@MainActor @Observable
final class AppModel {
    let orchestrator = Orchestrator()
    var status: AeroSpaceStatus = .notInstalled
    var lastMessage = ""
    private var watcher: ConfigWatcher?

    init() {
        do {
            try orchestrator.writeDefaultConfigIfMissing()
            try startWatching()
            try orchestrator.apply()
            lastMessage = "Config applied"
        } catch {
            lastMessage = "\(error)"
        }
        refreshStatus()
    }

    var launchAtLogin = false
    var dragToTileActive = false
    /// SMAppService needs a real bundle; the bare dev binary has no identifier.
    let isBundled = Bundle.main.bundleIdentifier != nil
    private var dragController: DragTileController?

    func refreshStatus() {
        status = orchestrator.status()
        if isBundled {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if !dragToTileActive {
            startDragToTileIfPermitted()
        }
    }

    func startDragToTileIfPermitted() {
        guard DragTileController.hasPermission else { return }
        let controller = dragController ?? DragTileController()
        controller.onStatus = { [weak self] message in
            Task { @MainActor in
                self?.lastMessage = message
            }
        }
        dragController = controller
        dragToTileActive = controller.start()
    }

    func enableDragToTile() {
        if DragTileController.hasPermission {
            startDragToTileIfPermitted()
            lastMessage = dragToTileActive ? "Drag-to-Tile active" : "Could not start event tap"
        } else {
            DragTileController.requestPermission()
            lastMessage = "Grant Input Monitoring to Panewright, then quit and reopen the app"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastMessage = enabled ? "Launch at login enabled" : "Launch at login disabled"
        } catch {
            lastMessage = "\(error)"
        }
        refreshStatus()
    }

    func apply() {
        do {
            try orchestrator.apply()
            lastMessage = "Config applied"
        } catch {
            lastMessage = "\(error)"
        }
        refreshStatus()
    }

    func openConfig() {
        NSWorkspace.shared.open(orchestrator.paths.panewrightConfigFile)
    }

    func launchOrRestartAeroSpace() {
        do {
            if status == .notRunning {
                try orchestrator.launchAeroSpace()
                lastMessage = "AeroSpace launched"
            } else {
                try orchestrator.restartAeroSpace()
                lastMessage = "AeroSpace restarted"
            }
        } catch {
            lastMessage = "\(error)"
        }
        refreshStatus()
    }

    private func startWatching() throws {
        let directory = orchestrator.paths.panewrightConfigFile.deletingLastPathComponent()
        let watcher = ConfigWatcher(directory: directory) { [weak self] in
            Task { @MainActor in
                self?.apply()
            }
        }
        try watcher.start()
        self.watcher = watcher
    }
}

struct PanewrightMenu: View {
    let model: AppModel

    var body: some View {
        Text(statusLine)
        if model.status == .unresponsive {
            Text("Grant Accessibility in System Settings, then restart AeroSpace")
        }
        Divider()
        Button("Edit Config…") {
            model.openConfig()
        }
        Button("Apply Config Now") {
            model.apply()
        }
        aeroSpaceButton
        if model.dragToTileActive {
            Text("Drag-to-Tile: active")
        } else {
            Button("Enable Drag-to-Tile…") {
                model.enableDragToTile()
            }
        }
        if model.isBundled {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
        }
        if !model.lastMessage.isEmpty {
            Divider()
            Text(model.lastMessage)
        }
        Divider()
        Button("Quit Panewright") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            model.refreshStatus()
        }
    }

    private var statusLine: String {
        "AeroSpace: \(model.status.description)"
    }

    @ViewBuilder
    private var aeroSpaceButton: some View {
        switch model.status {
        case .notRunning:
            Button("Launch AeroSpace") {
                model.launchOrRestartAeroSpace()
            }
        case .unresponsive, .running:
            Button("Restart AeroSpace") {
                model.launchOrRestartAeroSpace()
            }
        case .notInstalled:
            EmptyView()
        }
    }
}
