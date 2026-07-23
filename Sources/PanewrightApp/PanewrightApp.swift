import AppKit
import PanewrightCore
import SwiftUI

@main
struct PanewrightApp: App {
    @State private var model = AppModel()

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

    func refreshStatus() {
        status = orchestrator.status()
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
