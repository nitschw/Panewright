import AppKit
import PanewrightCore
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

/// Quit = restore vanilla macOS: tear the whole environment down. Signals
/// count as quitting too (`pkill`, logout), so they get the same treatment
/// instead of orphaning daemons.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    /// Set by the app so URL callbacks can reach the model.
    @MainActor static weak var model: AppModel?

    /// panewright://todo/add and panewright://todo/edit/<index> — the bar's
    /// popup can't draw a two-field form, so it asks the app to.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "panewright" {
            let parts = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
            MainActor.assumeIsolated {
                switch parts.first {
                case "todo":
                    switch parts.dropFirst().first {
                    case "add":
                        AppDelegate.model?.openTodoEditor(index: nil)
                    case "edit":
                        let index = parts.dropFirst(2).first.flatMap { Int($0) }
                        AppDelegate.model?.openTodoEditor(index: index)
                    default:
                        break
                    }
                case "integrations":
                    if parts.dropFirst().first == "confluence" {
                        AppDelegate.model?.openConfluence()
                    } else {
                        AppDelegate.model?.openIntegrations(service: parts.dropFirst().first)
                    }
                case "confluence":
                    AppDelegate.model?.openConfluence()
                default:
                    break
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask for the permissions the app can't work without — automatically,
        // but only once AppKit has settled. (Prompting during init throws
        // inside the first window-constraint pass; see AppModel.init.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard !DragTileController.hasPermission else { return }
            DragLog.log("requesting permissions (post-launch)")
            DragTileController.requestPermission()
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                DragLog.log("signal \(sig): tearing down")
                Orchestrator().teardown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Orchestrator().teardown()
    }
}

@main
struct PanewrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        defer { AppDelegate.model = model }
        // A window-layout exception must not take down the whole tiling
        // environment: log it (with its reason, unlike the crash reporter)
        // and carry on.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": false])
        NSSetUncaughtExceptionHandler { exception in
            DragLog.log(
                "UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "?")")
            for frame in exception.callStackSymbols.prefix(12) {
                DragLog.log("  \(frame)")
            }
        }
        Self.terminateIfAlreadyRunning()
    }

    /// Bare-executable dev builds have no bundle ID for the usual
    /// single-instance check, so match on process name instead.
    /// Deterministic tie-break — the eldest (lowest-pid) instance survives —
    /// so simultaneous launches can't mutually annihilate.
    private static func terminateIfAlreadyRunning() {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = otherInstancePIDs()
        DragLog.log("guard: mine=\(mine) others=\(others)")
        if others.contains(where: { $0 < mine }) {
            DragLog.log("guard: deferring to elder instance")
            exit(0)
        }
    }

    private static func otherInstancePIDs() -> [Int32] {
        let mine = ProcessInfo.processInfo.processIdentifier
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "panewright"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n")
            .compactMap { Int32($0) }
            .filter { $0 != mine }
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
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        do {
            try orchestrator.writeDefaultConfigIfMissing()
            try startWatching()
        } catch {
            report(error: "\(error)")
        }
        // Permissions gate everything: without them there's no drag engine,
        // and a grant made now can't bind until the process restarts. So
        // settle permissions FIRST and start nothing else until they're in
        // hand — the app relaunches itself the moment they're granted.
        //
        // (The prompt itself is raised post-launch by the app delegate;
        // raising a system dialog during init throws inside AppKit's first
        // window-constraint pass and kills the process.)
        if DragTileController.hasPermission {
            bootstrapEnvironment()
        } else {
            awaitingPermissions = true
            lastMessage = "Waiting for permissions…"
            startPermissionWatch()
        }
        // Detect (never present) last session's crash; the menu offers it.
        pendingCrashReport = CrashReporter.pendingReport()
        if pendingCrashReport != nil {
            notify("Panewright crashed last session — open the menu to report it")
        }
    }

    func reportPendingCrash() {
        guard let report = pendingCrashReport else { return }
        pendingCrashReport = nil
        CrashReporter.present(report: report)
    }

    private func notify(_ body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Panewright"
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Purge everything, then bring the environment up fresh — so a crash,
    /// a kill, or a half-finished previous session can't leave stragglers.
    func bootstrapEnvironment() {
        let orchestrator = orchestrator
        isBootstrapping = true
        lastMessage = "Starting environment…"
        let finished: @MainActor @Sendable () -> Void = { [weak self] in
            self?.isBootstrapping = false
            self?.lastMessage = "Environment ready"
            self?.refreshStatus()
            self?.offerSetupIfIncomplete()
            self?.startPermissionWatch()
        }
        Task.detached(priority: .userInitiated) {
            orchestrator.bootstrap()
            await finished()
        }
    }

    /// Nudge, don't interrupt: a notification and a marked menu item, never
    /// a window thrown at the user during startup.
    private func offerSetupIfIncomplete() {
        guard setupIncomplete, !autoOpenedSetup else { return }
        autoOpenedSetup = true
        notify("Setup isn't finished — open the Panewright menu → Setup…")
    }

    var launchAtLogin = false
    var dragToTileActive = false
    var bordersInfo = ""
    var bordersEnabled = true
    var barInfo = ""
    var barEnabled = true
    var needsDragSetup = false
    var isBootstrapping = false
    var autoOpenedSetup = false
    var pendingCrashReport: String?
    var confluenceEnabled = false
    var awaitingPermissions = false
    private var permissionWatch: Timer?
    var installing: Set<String> = []
    var setupVisible = false
    var profiles: [String] = []
    var activeProfile: String? = UserDefaults.standard.string(forKey: "activeProfile")
    private var setupWindowController: OnboardingWindowController?
    private var aboutWindowController: AboutWindowController?
    private var editorWindowController: EditorWindowController?
    private var todoWindowController: TodoEditorWindowController?
    private var integrationsWindowController: IntegrationsWindowController?
    private var confluenceWindowController: ConfluenceWindowController?
    let integrations = IntegrationsModel()
    /// Sparkle needs a real bundle; nil in bare dev runs.
    private var updaterController: SPUStandardUpdaterController?

    var aerospaceInstalled: Bool { AeroSpaceCLI.locate() != nil }
    var bordersInstalled: Bool { JankyBordersSupervisor.locate() != nil }
    var sketchybarInstalled: Bool { SketchyBarSupervisor.locate() != nil }
    var setupIncomplete: Bool {
        !(aerospaceInstalled && status == .running && DragTileController.hasPermission)
    }
    /// SMAppService needs a real bundle; the bare dev binary has no identifier.
    let isBundled = Bundle.main.bundleIdentifier != nil
    private var dragController: DragTileController?

    /// Status checks spawn processes; waitUntilExit on the main thread pumps
    /// the run loop, which lets AppKit re-enter mid-layout and crash. So:
    /// compute off-main, apply on main.
    func refreshStatus() {
        let orchestrator = orchestrator
        // MainActor closure built here so `self` never crosses the
        // detachment boundary — Swift 6.0 compilers insist.
        let apply:
            @MainActor @Sendable (AeroSpaceStatus, String, String, PanewrightConfig?, [String])
                -> Void = { [weak self] status, bordersInfo, barInfo, config, profiles in
                guard let self else { return }
                self.status = status
                self.bordersInfo = bordersInfo
                self.barInfo = barInfo
                self.bordersEnabled = config?.focusBorder.enabled ?? true
                self.barEnabled = config?.statusBar.enabled ?? true
                self.profiles = profiles
                self.dragController?.configure(
                    focusFollowsMouse: config?.focusFollowsMouse ?? false)
                self.integrations.configure(config?.integrations ?? IntegrationsConfig())
                self.confluenceEnabled = config?.integrations.confluence.enabled ?? false
                if self.isBundled {
                    self.launchAtLogin = SMAppService.mainApp.status == .enabled
                }
                if !self.dragToTileActive {
                    self.startDragToTileIfPermitted()
                }
                self.needsDragSetup = !DragTileController.hasPermission
            }
        Task.detached(priority: .utility) {
            let status = orchestrator.status()
            let bordersInfo = orchestrator.bordersInfo()
            let barInfo = orchestrator.barInfo()
            let config = try? orchestrator.loadConfig()
            let profiles = orchestrator.listProfiles()
            await apply(status, bordersInfo, barInfo, config, profiles)
        }
    }

    // MARK: Setup window

    func openConfluence() {
        let config = (try? orchestrator.loadConfig())?.integrations.confluence
        let controller = confluenceWindowController ?? ConfluenceWindowController()
        confluenceWindowController = controller
        controller.show(host: config?.host ?? "", email: config?.user ?? "")
    }

    func openIntegrations(service: String?) {
        let controller = integrationsWindowController ?? IntegrationsWindowController()
        integrationsWindowController = controller
        controller.show(model: integrations, service: service)
    }

    /// index nil = new task; otherwise edit that 0-based item.
    func openTodoEditor(index: Int?) {
        let controller = todoWindowController ?? TodoEditorWindowController()
        todoWindowController = controller
        controller.show(index: index) {
            // Repaint the bar item immediately.
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [
                "-c", "/opt/homebrew/bin/sketchybar --trigger panewright_todo 2>/dev/null",
            ]
            try? process.run()
        }
    }

    func openEditor() {
        let controller = editorWindowController ?? EditorWindowController()
        editorWindowController = controller
        controller.show(appModel: self)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updaterController != nil
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

    /// TCC grants only bind at process start, so a grant given while we're
    /// running does nothing until we relaunch. Watch for it and do that
    /// ourselves — the user already said yes; don't make them say it twice.
    func startPermissionWatch() {
        guard !dragToTileActive, permissionWatch == nil else { return }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.checkForFreshGrant()
            }
        }
    }

    private func checkForFreshGrant() {
        guard !dragToTileActive else {
            permissionWatch?.invalidate()
            permissionWatch = nil
            return
        }
        guard DragTileController.hasPermission else { return }
        permissionWatch?.invalidate()
        permissionWatch = nil
        // Launched without permissions: nothing has been started, so take
        // the clean path — tear down and respawn into a process that can
        // actually use the grant.
        if awaitingPermissions {
            DragLog.log("permissions granted — respawning")
            relaunch()
            return
        }
        // Granted mid-session: try in place, relaunch only if the tap
        // still can't be created.
        startDragToTileIfPermitted()
        if dragToTileActive {
            lastMessage = "Drag-to-Tile active"
        } else {
            DragLog.log("permission granted but tap needs a fresh process — relaunching")
            relaunch()
        }
    }

    /// Relaunch cleanly: spawn a detached starter that waits for this
    /// process to exit (the single-instance guard defers to the elder).
    func relaunch() {
        lastMessage = "Restarting to apply permissions…"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 3; open -a Panewright"]
        try? process.run()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }

    /// User-initiated only (Setup window) — see the note in `init`.
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
            // Self-heal the layouts a restart scrambles.
            let orchestrator = orchestrator
            Task.detached(priority: .utility) {
                orchestrator.healLayoutsWhenReady()
            }
        } catch {
            report(error: "\(error)")
        }
        refreshStatus()
    }

    private func startWatching() throws {
        let directory = orchestrator.paths.panewrightConfigFile.deletingLastPathComponent()
        let watcher = ConfigWatcher(
            directory: directory, file: orchestrator.paths.panewrightConfigFile
        ) { [weak self] in
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
        if model.awaitingPermissions {
            Text("Waiting for permissions…")
            Button("Grant Permissions…") {
                model.finishDragToTileSetup()
            }
            Divider()
        }
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
        Button("Add Task…") {
            model.openTodoEditor(index: nil)
        }
        if !model.integrations.services.isEmpty {
            Button("Work Items…") {
                model.openIntegrations(service: nil)
            }
        }
        if model.confluenceEnabled {
            Button("Confluence…") {
                model.openConfluence()
            }
        }
        Button("Open Editor…") {
            model.openEditor()
        }
        Button("Edit Config File…") {
            model.openConfig()
        }
        Button(model.setupIncomplete ? "⚠ Setup…" : "Setup…") {
            model.openSetup()
        }
        if model.pendingCrashReport != nil {
            Button("Report Last Crash…") {
                model.reportPendingCrash()
            }
        }
        Button(model.isBootstrapping ? "Restarting Environment…" : "Restart Environment") {
            model.bootstrapEnvironment()
        }
        .disabled(model.isBootstrapping)
        Button("Apply Config Now") {
            model.apply()
        }
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
        if model.canCheckForUpdates {
            Button("Check for Updates…") {
                model.checkForUpdates()
            }
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

}
