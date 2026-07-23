import AppKit
import PanewrightCore
import ServiceManagement
import SwiftUI
import UserNotifications

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
        if isBundled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        do {
            try orchestrator.writeDefaultConfigIfMissing()
            try startWatching()
            try orchestrator.apply()
            lastMessage = "Config applied"
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
        // Drag-to-tile is core behavior, not an option: ask for its
        // permission on first launch rather than waiting to be enabled.
        if !dragToTileActive {
            DragTileController.requestPermission()
        }
        // First-run: open the setup checklist when essentials are missing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.setupIncomplete else { return }
            self.openSetup()
        }
    }

    var launchAtLogin = false
    var dragToTileActive = false
    var bordersInfo = ""
    var bordersEnabled = true
    var barInfo = ""
    var barEnabled = true
    var needsDragSetup = false
    var installing: Set<String> = []
    var setupVisible = false
    var profiles: [String] = []
    var activeProfile: String? = UserDefaults.standard.string(forKey: "activeProfile")
    private var setupWindowController: OnboardingWindowController?
    private var aboutWindowController: AboutWindowController?
    private var editorWindowController: EditorWindowController?

    var aerospaceInstalled: Bool { AeroSpaceCLI.locate() != nil }
    var bordersInstalled: Bool { JankyBordersSupervisor.locate() != nil }
    var sketchybarInstalled: Bool { SketchyBarSupervisor.locate() != nil }
    var setupIncomplete: Bool {
        !(aerospaceInstalled && status == .running && DragTileController.hasPermission)
    }
    /// SMAppService needs a real bundle; the bare dev binary has no identifier.
    let isBundled = Bundle.main.bundleIdentifier != nil
    private var dragController: DragTileController?

    func refreshStatus() {
        status = orchestrator.status()
        bordersInfo = orchestrator.bordersInfo()
        barInfo = orchestrator.barInfo()
        let config = try? orchestrator.loadConfig()
        bordersEnabled = config?.focusBorder.enabled ?? true
        barEnabled = config?.statusBar.enabled ?? true
        dragController?.configure(focusFollowsMouse: config?.focusFollowsMouse ?? false)
        if isBundled {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if !dragToTileActive {
            startDragToTileIfPermitted()
        }
        needsDragSetup = !DragTileController.hasPermission
        profiles = orchestrator.listProfiles()
    }

    // MARK: Setup window

    func openEditor() {
        let controller = editorWindowController ?? EditorWindowController()
        editorWindowController = controller
        controller.show(appModel: self)
    }

    func openAbout() {
        let controller = aboutWindowController ?? AboutWindowController()
        aboutWindowController = controller
        controller.show()
    }

    func openSetup() {
        let controller = setupWindowController ?? OnboardingWindowController()
        setupWindowController = controller
        controller.onVisibilityChange = { [weak self] visible in
            Task { @MainActor in
                self?.setupVisible = visible
            }
        }
        controller.show(model: self)
        setupVisible = true
        refreshStatus()
    }

    // MARK: Tool installation (Homebrew, no password required)

    func installAeroSpace() {
        installTool("AeroSpace", brewArguments: ["install", "--cask", "nikitabobko/tap/aerospace"])
    }

    func installBorders() {
        installTool("JankyBorders", brewArguments: ["install", "FelixKratz/formulae/borders"])
    }

    func installSketchyBar() {
        installTool("SketchyBar", brewArguments: ["install", "FelixKratz/formulae/sketchybar"])
    }

    private func installTool(_ name: String, brewArguments: [String]) {
        guard let brew = Self.locateBrew() else {
            report(error: "Homebrew not found — install it from brew.sh first")
            return
        }
        guard !installing.contains(name) else { return }
        installing.insert(name)
        lastMessage = "Installing \(name)…"
        Task {
            let ok = await Self.runProcess(executable: brew, arguments: brewArguments)
            installing.remove(name)
            if ok {
                lastMessage = "\(name) installed"
                if name == "AeroSpace" {
                    try? orchestrator.launchAeroSpace()
                }
                apply()
            } else {
                report(error: "\(name) install failed")
            }
            refreshStatus()
        }
    }

    static func locateBrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    nonisolated static func runProcess(executable: URL, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["NONINTERACTIVE"] = "1"
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    // MARK: Profiles

    func activateProfile(_ name: String) {
        do {
            try orchestrator.activateProfile(named: name)
            activeProfile = name
            UserDefaults.standard.set(name, forKey: "activeProfile")
            lastMessage = "Profile '\(name)' active"
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
    }

    func saveCurrentAsProfile() {
        let alert = NSAlert()
        alert.messageText = "Save Current Config as Profile"
        alert.informativeText = "Profiles are full copies of panewright.toml, switchable from the menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. work, docked, demo"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        do {
            try orchestrator.saveProfile(named: name)
            activeProfile = name.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(activeProfile, forKey: "activeProfile")
            lastMessage = "Saved profile '\(name)'"
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
    }

    func startDragToTileIfPermitted() {
        guard DragTileController.hasPermission else { return }
        let controller = dragController ?? DragTileController()
        controller.configure(
            focusFollowsMouse: (try? orchestrator.loadConfig())?.focusFollowsMouse ?? false)
        controller.onStatus = { [weak self] message in
            Task { @MainActor in
                self?.reportDropResult(message)
            }
        }
        dragController = controller
        dragToTileActive = controller.start()
    }

    func finishDragToTileSetup() {
        DragTileController.requestPermission()
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
        lastMessage =
            "Enable Panewright under Accessibility (and Input Monitoring), then quit and reopen the app"
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

    /// Errors go to the menu AND a notification — silence is how half this
    /// project's bugs stayed hidden.
    func report(error message: String) {
        lastMessage = message
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Panewright"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func apply() {
        do {
            try orchestrator.apply()
            lastMessage = "Config applied"
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
    }

    func setBordersEnabled(_ enabled: Bool) {
        do {
            try orchestrator.setBordersEnabled(enabled)
            lastMessage = enabled ? "Borders on" : "Borders off"
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
    }

    func setBarEnabled(_ enabled: Bool) {
        do {
            try orchestrator.setBarEnabled(enabled)
            lastMessage = enabled ? "Status bar on" : "Status bar off"
        } catch {
            report(error: "\(error)")
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
            report(error: "\(error)")
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

    func reportDropResult(_ message: String) {
        let failureMarkers = ["failed", "couldn't", "gave up", "lost", "oscillation"]
        if failureMarkers.contains(where: message.contains) {
            report(error: message)
        } else {
            lastMessage = message
        }
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
        Menu("Profiles") {
            ForEach(model.profiles, id: \.self) { name in
                Button(name == model.activeProfile ? "✓ \(name)" : name) {
                    model.activateProfile(name)
                }
            }
            if !model.profiles.isEmpty {
                Divider()
            }
            Button("Save Current as Profile…") {
                model.saveCurrentAsProfile()
            }
        }
        Button("Open Editor…") {
            model.openEditor()
        }
        Button("Edit Config File…") {
            model.openConfig()
        }
        Button("Setup…") {
            model.openSetup()
        }
        Button("Apply Config Now") {
            model.apply()
        }
        aeroSpaceButton
        if model.bordersInfo == "not installed" {
            Text("Borders: not installed")
        } else {
            Toggle(
                "Focus Borders",
                isOn: Binding(
                    get: { model.bordersEnabled },
                    set: { model.setBordersEnabled($0) }
                ))
        }
        if model.barInfo == "not installed" {
            Text("Status Bar: not installed")
        } else {
            Toggle(
                "Status Bar",
                isOn: Binding(
                    get: { model.barEnabled },
                    set: { model.setBarEnabled($0) }
                ))
        }
        if model.needsDragSetup {
            Button("Finish Drag-to-Tile setup…") {
                model.finishDragToTileSetup()
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
        Button("About Panewright") {
            model.openAbout()
        }
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
