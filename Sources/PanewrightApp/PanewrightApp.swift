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
                    // panewright://confluence/page/<id> deep-links an article.
                    let pageID =
                        parts.dropFirst().first == "page"
                        ? parts.dropFirst(2).first : nil
                    AppDelegate.model?.openConfluence(pageID: pageID)
                case "help":
                    AppDelegate.model?.openCheatSheet()
                case "conflicts":
                    AppDelegate.model?.openConflicts()
                case "settings":
                    // panewright://settings[/keys|/layout|/appearance|/bar]
                    // — the deep link external tools (and the Raycast
                    // extension) use to land on a specific tab.
                    AppDelegate.model?.openSettings(
                        reveal: SettingsModel.Target(tab: parts.dropFirst().first))
                case "widgets":
                    if parts.dropFirst().first == "disable",
                        let key = parts.dropFirst(2).first
                    {
                        AppDelegate.model?.disableWidget(key: key)
                    } else {
                        AppDelegate.model?.openSettings(reveal: .widgets)
                    }
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
        // Refuse to bring up a second window manager on top of someone else's.
        // Both engines would watch the same windows and undo each other, and
        // the fitting loop would read their placement as a broken layout and
        // "correct" it forever. Failing to start, loudly, is kinder than that.
        competingTools = Self.detectCompetingTools()
        if !competingTools.isEmpty, !startedDespiteCompetition {
            let explanation = CompetingWindowManagers.explanation(for: competingTools)
            lastMessage = explanation
            DragLog.log("startup: held back — \(competingTools.map(\.name).joined(separator: ", "))")
            notify(explanation)
            return
        }
        let orchestrator = orchestrator
        isBootstrapping = true
        lastMessage = "Starting environment…"
        let finished: @MainActor @Sendable () -> Void = { [weak self] in
            self?.isBootstrapping = false
            self?.lastMessage = "Environment ready"
            self?.refreshStatus()
            self?.offerSetupIfIncomplete()
            self?.startPermissionWatch()
            self?.startBarHealthCheck()
            self?.startWindowFitting()
            self?.appSwitchRouter.start()
            MonitorMap.observe()
        }
        Task.detached(priority: .userInitiated) {
            orchestrator.bootstrap()
            await finished()
        }
    }

    /// GUI apps are matched on bundle ID; command-line daemons like yabai
    /// have none, so those are matched on process name.
    private static func detectCompetingTools() -> [CompetingWindowManagers.Tool] {
        let bundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var processNames: Set<String> = []
        for tool in CompetingWindowManagers.known {
            guard let process = tool.processName else { continue }
            let pgrep = Process()
            pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", process]
            pgrep.standardOutput = Pipe()
            pgrep.standardError = Pipe()
            guard (try? pgrep.run()) != nil else { continue }
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 0 { processNames.insert(process) }
        }
        return CompetingWindowManagers.running(
            bundleIDs: bundleIDs, processNames: processNames)
    }

    /// Proceed knowing the layout will be contested. Not persisted — the next
    /// launch checks again, so this can't be dismissed permanently by accident.
    func startAnywayDespiteCompetition() {
        startedDespiteCompetition = true
        competingTools = []
        bootstrapEnvironment()
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
    private var cheatSheetWindowController: CheatSheetWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var conflictsWindowController: ConflictsWindowController?
    private var profilesWindowController: ProfilesWindowController?
    private var windowFitController: WindowFitController?
    private let shortcutOverride = ShortcutOverrideTap()
    private let appSwitchRouter = AppSwitchRouter()
    /// Deliberately not persisted: a tap that swallows keystrokes must always
    /// be off after a restart, so quitting Panewright is a guaranteed way out
    /// of a keyboard that's misbehaving.
    var overridingShortcuts = false
    /// Window managers found running at launch. Non-empty means the
    /// environment was held back rather than started.
    var competingTools: [CompetingWindowManagers.Tool] = []
    /// Set when the user chooses to start anyway. Session only: a fresh launch
    /// re-checks, so the gate can't be permanently dismissed by accident.
    var startedDespiteCompetition = false
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
                self.dragController?.configure(
                    dragToBar: config?.pills.dragToBar ?? true)
                self.integrations.configure(config?.integrations ?? IntegrationsConfig())
                self.confluenceEnabled = config?.integrations.confluence.enabled ?? false
                self.conflictCount = config.map { BindingConflicts.rows(in: $0).count } ?? 0
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

    /// Persist a whole widget set and repaint — used by the picker and by
    /// right-clicking a widget in the bar.
    func applyModules(
        _ updated: PanewrightConfig.Modules, integrations: IntegrationsConfig? = nil,
        todoEnabled: Bool? = nil, pillsEnabled: Bool? = nil
    ) {
        do {
            var config = try orchestrator.loadConfig()
            // These three build their own bar items at config time, so they're
            // the only toggles that still need the bar rebuilt.
            let rebuildNeeded =
                (integrations.map { $0 != config.integrations } ?? false)
                || (todoEnabled.map { $0 != config.todo.enabled } ?? false)
                || (pillsEnabled.map { $0 != config.pills.enabled } ?? false)
            config.modules = updated
            if let integrations { config.integrations = integrations }
            if let todoEnabled { config.todo.enabled = todoEnabled }
            if let pillsEnabled { config.pills.enabled = pillsEnabled }
            try orchestrator.writeConfig(config)
            // Work widgets live in their own bar items created at build time,
            // so toggling one still needs the bar rebuilt; the rest don't.
            if rebuildNeeded {
                try orchestrator.applyBar(config)
                self.integrations.configure(config.integrations)
            } else {
                try orchestrator.refreshWidgets(config)
            }
        } catch {
            report(error: "\(error)")
        }
    }

    /// panewright://widgets/disable/<key> — the bar's right-click action.
    func disableWidget(key: String) {
        guard let entry = PanewrightConfig.Modules.catalog.first(where: { $0.key == key })
        else { return }
        var updated = modules
        updated[keyPath: entry.path] = false
        applyModules(updated)
        lastMessage = "\(entry.name) widget off"
    }

    func openCheatSheet() {
        let config = (try? orchestrator.loadConfig()) ?? .default
        let controller = cheatSheetWindowController ?? CheatSheetWindowController()
        cheatSheetWindowController = controller
        controller.show(config: config)
    }

    func openConfluence(pageID: String? = nil) {
        let config = (try? orchestrator.loadConfig())?.integrations.confluence
        let controller = confluenceWindowController ?? ConfluenceWindowController()
        confluenceWindowController = controller
        controller.show(
            host: config?.host ?? "", email: config?.user ?? "", pageID: pageID)
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

    func openSettings(reveal: SettingsModel.Target? = nil) {
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.show(appModel: self, reveal: reveal)
    }

    /// Take the chords macOS reserves, so bindings on them can work. Session
    /// only — never written to the config.
    func toggleShortcutOverride() {
        overridingShortcuts.toggle()
        if overridingShortcuts {
            shortcutOverride.configure(with: (try? orchestrator.loadConfig()) ?? .default)
            guard !shortcutOverride.overriddenChords.isEmpty else {
                overridingShortcuts = false
                lastMessage = "No system-reserved chords to take"
                return
            }
            shortcutOverride.start()
            lastMessage = "Taking \(shortcutOverride.overriddenChords.joined(separator: ", "))"
        } else {
            shortcutOverride.stop()
            lastMessage = "System shortcuts released"
        }
    }

    func openProfiles() {
        let controller = profilesWindowController ?? ProfilesWindowController()
        profilesWindowController = controller
        controller.show(appModel: self)
    }

    /// Kept in sync when a profile is renamed or deleted, so the checkmark
    /// doesn't point at a name that no longer exists.
    func setActiveProfile(_ name: String?) {
        activeProfile = name
        if let name {
            UserDefaults.standard.set(name, forKey: "activeProfile")
        } else {
            UserDefaults.standard.removeObject(forKey: "activeProfile")
        }
    }

    /// panewright://conflicts — the bar's ⚠ chip, and the menu item.
    func openConflicts() {
        let controller = conflictsWindowController ?? ConflictsWindowController()
        conflictsWindowController = controller
        controller.show(appModel: self)
    }

    /// How many bindings currently can't do what they say — drives the menu
    /// item, so the menu tells the same story as the bar's ⚠ chip. Refreshed
    /// with the rest of the status (off-main; the menu body must not parse
    /// the config on every redraw).
    var conflictCount = 0

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
        let config = try? orchestrator.loadConfig()
        controller.configure(focusFollowsMouse: config?.focusFollowsMouse ?? false)
        controller.configure(dragToBar: config?.pills.dragToBar ?? true)
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

    /// Current widget toggles, read fresh so the menu reflects hand edits to
    /// panewright.toml as well as menu clicks.
    var modules: PanewrightConfig.Modules {
        (try? orchestrator.loadConfig())?.modules ?? .init()
    }

    /// Flip one widget and re-apply — the menu is the discoverable way in, so
    /// nobody has to learn the TOML keys to find out what's available.
    func setWidget(_ path: WritableKeyPath<PanewrightConfig.Modules, Bool>, _ on: Bool, name: String)
    {
        do {
            var config = try orchestrator.loadConfig()
            config.modules[keyPath: path] = on
            try orchestrator.writeConfig(config)
            // Runtime toggle, not a bar rebuild — reloading tore the bar down
            // and rebuilt it, which read as the whole bar glitching.
            try orchestrator.refreshWidgets(config)
            lastMessage = "\(name) widget \(on ? "on" : "off")"
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

    /// The bar has vanished before without leaving a crash report (a display
    /// sleep/wake took it down); nothing restarted it until the app was
    /// relaunched. Supervise it: if the bar should be up and isn't, bring it
    /// back.
    /// Corrects windows that render over each other because their app won't
    /// shrink any further. Idle unless windows actually overlap.
    private func startWindowFitting() {
        guard windowFitController == nil else { return }
        let controller = WindowFitController { [weak self] message in
            self?.notify(message)
            self?.lastMessage = message
        }
        windowFitController = controller
        controller.start()
    }

    private func startBarHealthCheck() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task.detached(priority: .utility) {
                let orchestrator = Orchestrator()
                if let config = try? orchestrator.loadConfig(), config.statusBar.enabled,
                    let bar = SketchyBarSupervisor.locate(), !bar.isRunning()
                {
                    DragLog.log("bar health: sketchybar is down — restarting")
                    try? orchestrator.applyBar(config)
                }
                await self?.checkAeroSpaceHealth(orchestrator)
                Self.refreshBrewOutdatedCache()
            }
        }
    }

    /// `brew outdated` from the app, not the bar plugin: SketchyBar's spawn
    /// environment makes brew return nothing, and the widget would cache that
    /// empty result. Hourly, and only publishes a value brew actually produced.
    nonisolated static func refreshBrewOutdatedCache() {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/panewright/.brew-outdated")
        // Rate-limit on the file's own mtime — no shared state, so this is
        // safe to call from the detached health-check task.
        // Older builds cached a bare count. Refresh those immediately rather
        // than showing "1 outdated package called 19" for up to an hour.
        let existing = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
        let looksLegacy =
            !existing.isEmpty
            && existing.split(separator: "\n").count == 1
            && existing.trimmingCharacters(in: .whitespacesAndNewlines)
                .allSatisfy(\.isNumber)
        if !looksLegacy,
            let attrs = try? FileManager.default.attributesOfItem(atPath: cache.path),
            let modified = attrs[.modificationDate] as? Date,
            Date().timeIntervalSince(modified) < 3600
        {
            return
        }
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = ["outdated", "--quiet"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            // The names, not the tally. "19 packages are out of date" tells
            // you nothing you can act on; knowing *which* is the whole point
            // of the indicator.
            let names = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DragLog.log("brew: \(names.count) outdated")
            try? names.joined(separator: "\n").write(
                to: cache, atomically: true, encoding: .utf8)
            return
        }
    }

    /// AeroSpace can lose its Accessibility connection under load and manage
    /// nothing while windows are clearly on screen. Try one restart to shake it
    /// loose; if it stays blind, the permission needs re-granting — which only
    /// the user can do, so tell them (once) instead of thrashing.
    private var aeroStallRestarted = false
    private var aeroStallNotified = false
    private func checkAeroSpaceHealth(_ orchestrator: Orchestrator) async {
        let onScreen = WindowSnapshot.capture().filter {
            !Self.systemOwners.contains($0.ownerName)
        }.count
        guard orchestrator.aeroSpaceIsStalled(visibleAppWindowCount: onScreen) else {
            // Recovered (or never stalled): rearm both stages for next time.
            aeroStallRestarted = false
            aeroStallNotified = false
            return
        }
        if !aeroStallRestarted {
            aeroStallRestarted = true
            DragLog.log("aerospace health: stalled (0 managed, \(onScreen) on screen) — restarting")
            try? orchestrator.restartAeroSpace()
            return  // give the restart a cycle before judging it failed
        }
        // A process restart didn't restore the Accessibility connection, so the
        // permission is wedged at the OS level — only the user can clear it.
        // Say so exactly once, not every cycle.
        guard !aeroStallNotified else { return }
        aeroStallNotified = true
        DragLog.log("aerospace health: still stalled after restart — notifying")
        notify(
            "Window tiling stopped responding. AeroSpace lost Accessibility access — "
                + "toggle it off and on in System Settings → Privacy & Security → Accessibility.")
    }

    /// Menu-bar/overlay owners that legitimately have no AeroSpace-managed
    /// windows, so they don't inflate the on-screen count in the stall check.
    private static let systemOwners: Set<String> = [
        "Panewright", "borders", "SketchyBar", "Window Server", "Dock", "Control Center",
    ]

    private func startWatching() throws {
        let directory = orchestrator.paths.panewrightConfigFile.deletingLastPathComponent()
        let watcher = ConfigWatcher(
            directory: directory, file: orchestrator.paths.panewrightConfigFile
        ) { [weak self] in
            DragLog.log("watch: config changed on disk — applying")
            Task { @MainActor in
                self?.apply()
            }
        }
        try watcher.start()
        self.watcher = watcher
        DragLog.log("watch: watching \(directory.path)")
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

    /// Grouped by what you came here to do, with a divider between groups:
    /// what's wrong, what you're configuring, what you're working on, the
    /// environment itself, and the app. It grew item by item before this,
    /// which is how "Add Task" ended up next to "Launch at Login".
    var body: some View {
        status
        Divider()
        attention
        configure
        Divider()
        work
        environment
        Divider()
        about
    }

    // MARK: What's going on

    @ViewBuilder
    private var status: some View {
        if !model.competingTools.isEmpty {
            Text("⚠ Another window manager is running")
            ForEach(model.competingTools) { tool in
                Text("  \(tool.name) — \(tool.note)")
            }
            Button("Start Anyway") { model.startAnywayDespiteCompetition() }
        } else if model.awaitingPermissions {
            Text("Waiting for permissions…")
            Button("Grant Permissions…") { model.finishDragToTileSetup() }
        } else {
            Text("AeroSpace: \(model.status.description)")
            if model.status == .unresponsive {
                Text("Grant Accessibility in System Settings, then restart AeroSpace")
            }
        }
    }

    /// Only ever shown when there's something to act on, so an ordinary menu
    /// has no warnings in it at all and a warning means something.
    @ViewBuilder
    private var attention: some View {
        if model.conflictCount > 0 {
            Button("⚠ Keybinding Conflicts (\(model.conflictCount))…") {
                model.openConflicts()
            }
            Button(
                model.overridingShortcuts
                    ? "✓ Overriding System Shortcuts" : "Override System Shortcuts"
            ) {
                model.toggleShortcutOverride()
            }
        }
        if model.setupIncomplete {
            Button("⚠ Finish Setup…") { model.openSetup() }
        }
        if model.needsDragSetup {
            Button("⚠ Finish Drag-to-Tile Setup…") { model.finishDragToTileSetup() }
        }
        if model.pendingCrashReport != nil {
            Button("⚠ Report Last Crash…") { model.reportPendingCrash() }
        }
        if model.conflictCount > 0 || model.setupIncomplete || model.needsDragSetup
            || model.pendingCrashReport != nil
        {
            Divider()
        }
    }

    // MARK: Configuring

    @ViewBuilder
    private var configure: some View {
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        Button("Profiles…") { model.openProfiles() }
        Button("Cheat Sheet") { model.openCheatSheet() }
        Button("Edit Config File…") { model.openConfig() }
        if !model.setupIncomplete {
            Button("Setup…") { model.openSetup() }
        }
    }

    // MARK: Work items — only when a service is configured

    @ViewBuilder
    private var work: some View {
        if !model.integrations.services.isEmpty {
            Button("Work Items…") { model.openIntegrations(service: nil) }
        }
        if model.confluenceEnabled {
            Button("Confluence…") { model.openConfluence() }
        }
        if !model.integrations.services.isEmpty || model.confluenceEnabled {
            Divider()
        }
    }

    // MARK: The running environment

    @ViewBuilder
    private var environment: some View {
        Button(model.isBootstrapping ? "Restarting Environment…" : "Restart Environment") {
            model.bootstrapEnvironment()
        }
        .disabled(model.isBootstrapping)
        Button("Apply Config Now") { model.apply() }
        // The status bar has no toggle here: it's how you see workspaces,
        // to-dos and conflicts, so turning it off from a menu is a good way
        // to lose the interface by accident. Settings still has it.
        if model.bordersInfo == "not installed" {
            Text("Focus Borders: not installed")
        } else {
            Toggle(
                "Focus Borders",
                isOn: Binding(
                    get: { model.bordersEnabled },
                    set: { model.setBordersEnabled($0) }))
        }
        if model.isBundled {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
        }
    }

    // MARK: The app

    @ViewBuilder
    private var about: some View {
        Button("About Panewright") { model.openAbout() }
        if model.canCheckForUpdates {
            Button("Check for Updates…") { model.checkForUpdates() }
        }
        Button("Quit Panewright") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { model.refreshStatus() }
    }

    private var statusLine: String {
        "AeroSpace: \(model.status.description)"
    }

}
