import AppKit
import ApplicationServices
import PanewrightCore

/// The quake terminal (`` $mod+` ``): one designated app summoned to the top
/// strip of the screen, dismissed with the same key. Hiro ships this bound
/// to Ghostty specifically; here it's the scratchpad's parking machinery
/// pointed at whichever terminal is installed, plus one AX placement.
///
/// AX positioning is safe here and only here: the summoned window is made
/// floating first, and the engine recomputes frames only for *tiled*
/// windows — a floating window's frame belongs to whoever set it last.
@MainActor
enum DropdownController {
    /// The usual suspects, best first. The first one installed wins.
    private static let terminals = [
        "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
        "dev.warp.Warp", "com.apple.Terminal",
    ]

    /// The frame the user last had it at — resizing the dropdown is a
    /// statement about how big it should be, and resetting to the config
    /// height on every summon would overrule it. Config height seeds the
    /// first summon; the memory holds for the rest of the app's run.
    private static var rememberedFrame: CGRect?

    /// THE dropdown window. One window earns the job and keeps it: the old
    /// any-window-of-the-app logic dismissed whatever iTerm happened to be
    /// on the current workspace (tiled work terminals included) and
    /// summoned an arbitrary other one — with several windows open the key
    /// cycled through them all instead of toggling one. Adoption order when
    /// nobody holds the job: a window already parked on S (the previous
    /// dropdown, surviving an app restart), the focused window if it's the
    /// right app (a deliberate "make this one the dropdown"), then the
    /// app's frontmost window. Every other window of the app is a civilian.
    private(set) static var designated: UInt32?
    /// Set once a window has ever held the job. When the designated window
    /// later dies, the next toggle spawns a FRESH window instead of
    /// conscripting one of the user's working terminals — the ghost is a
    /// scratchpad, and a scratchpad that dies gets reincarnated, not
    /// replaced by a hostage.
    private static var everDesignated = false

    static func toggle() {
        guard let config = try? Orchestrator().loadConfig(), config.dropdown.enabled,
            let cli = AeroSpaceCLI.locate()
        else { return }
        guard let appID = config.dropdown.app ?? installedTerminal() else {
            DragLog.log("dropdown: no terminal found to summon")
            return
        }
        let focusedWorkspace =
            (try? cli.run(["list-workspaces", "--focused"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        // Every window of the app, with its workspace.
        var appWindows: [(id: UInt32, workspace: String)] = []
        if let listing = try? cli.run([
            "list-windows", "--all", "--format",
            "%{window-id}|%{app-bundle-id}|%{workspace}",
        ]) {
            for line in listing.split(separator: "\n") {
                let parts = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count >= 3, parts[1] == appID, let id = UInt32(parts[0]) {
                    appWindows.append((id, parts[2]))
                }
            }
        }
        if let current = designated, !appWindows.contains(where: { $0.id == current }) {
            designated = nil  // it closed; the job is open again
        }
        // A dead ghost reincarnates: spawn a fresh window rather than
        // adopting one the user is working in. (First-ever designation still
        // adopts — the user's focused terminal is a deliberate choice then.)
        if designated == nil, everDesignated {
            DragLog.log("dropdown: ghost died — spawning a fresh one")
            spawnNewWindow(appID: appID) { newID in
                designated = newID
                DragLog.log("dropdown: window \(newID) is the reincarnated dropdown")
                summon(id: newID, appID: appID, to: focusedWorkspace, config: config, cli: cli)
            }
            return
        }
        if designated == nil {
            let focusedID = (try? cli.run([
                "list-windows", "--focused", "--format", "%{window-id}|%{app-bundle-id}",
            ]))
                .flatMap { listing -> UInt32? in
                    let parts = listing.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "|")
                    return parts.count >= 2 && parts[1] == appID
                        ? UInt32(parts[0]) : nil
                }
            let frontmost = WindowSnapshot.capture()
                .first { window in appWindows.contains { $0.id == window.id } }?.id
            designated =
                appWindows.first(where: { $0.workspace == "S" })?.id
                ?? focusedID ?? frontmost
            if let designated {
                everDesignated = true
                DragLog.log("dropdown: window \(designated) is now the dropdown")
            }
        }
        if let id = designated, let home = appWindows.first(where: { $0.id == id }) {
            if home.workspace == focusedWorkspace {
                DragLog.log("dropdown: dismissing \(appID)")
                // Capture the size on the way out — this is the moment the
                // user's resizes are the window's truth.
                if let frame = WindowSnapshot.frame(of: id) {
                    rememberedFrame = frame
                }
                _ = try? cli.run(["move-node-to-workspace", "--window-id", "\(id)", "S"])
            } else {
                summon(id: id, appID: appID, to: focusedWorkspace, config: config, cli: cli)
            }
            return
        }
        // No window of the app at all: launch it.
        do {
            DragLog.log("dropdown: launching \(appID)")
            guard
                let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: appID)
            else { return }
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
            // The window appears whenever the app finishes launching; try for
            // a few seconds, then give up quietly.
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(300))
                    if let id = windowID(of: appID, cli: cli) {
                        designated = id
                        DragLog.log("dropdown: window \(id) is now the dropdown")
                        summon(
                            id: id, appID: appID, to: focusedWorkspace,
                            config: config, cli: cli)
                        return
                    }
                }
                DragLog.log("dropdown: \(appID) launched but showed no window")
            }
        }
    }

    /// Ask the app for a genuinely new window, then wait for its id to
    /// appear. AppleScript for the terminals that support it properly;
    /// `open -n` as the generic fallback.
    private static func spawnNewWindow(appID: String, then: @escaping @MainActor (UInt32) -> Void) {
        let before = Set(WindowSnapshot.capture().map(\.id))
        let script: [String]? =
            switch appID {
            case "com.googlecode.iterm2":
                ["-e", "tell application \"iTerm2\" to create window with default profile"]
            case "com.apple.Terminal":
                ["-e", "tell application \"Terminal\" to do script \"\""]
            default: nil
            }
        if let script {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = script
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        Task { @MainActor in
            guard let cli = AeroSpaceCLI.locate() else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(300))
                let fresh = WindowSnapshot.capture().map(\.id).filter { !before.contains($0) }
                if let listing = try? cli.run([
                    "list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}",
                ]) {
                    for line in listing.split(separator: "\n") {
                        let parts = line.split(separator: "|").map {
                            $0.trimmingCharacters(in: .whitespaces)
                        }
                        if parts.count >= 2, parts[1] == appID, let id = UInt32(parts[0]),
                            fresh.contains(id)
                        {
                            then(id)
                            return
                        }
                    }
                }
            }
            DragLog.log("dropdown: asked \(appID) for a new window but none appeared")
        }
    }

    private static func windowID(of appID: String, cli: AeroSpaceCLI) -> UInt32? {
        guard
            let listing = try? cli.run([
                "list-windows", "--all", "--format", "%{window-id}|%{app-bundle-id}",
            ])
        else { return nil }
        for line in listing.split(separator: "\n") where line.hasSuffix("|\(appID)") {
            return UInt32(line.split(separator: "|")[0])
        }
        return nil
    }

    private static func summon(
        id: UInt32, appID: String, to workspace: String,
        config: PanewrightConfig, cli: AeroSpaceCLI
    ) {
        DragLog.log("dropdown: summoning \(appID) (\(id))")
        _ = try? cli.run(["move-node-to-workspace", "--window-id", "\(id)", workspace])
        _ = try? cli.run(["layout", "floating", "--window-id", "\(id)"])
        // Quake terminals drop from the top of the monitor you're looking
        // at, and "looking at" is the focused monitor, i3-style.
        guard let screen = Monitors.focusedScreen() else { return }
        // The remembered size only carries across summons on glass it fits:
        // a frame resized on a portrait 4K, replayed on the laptop lid,
        // lands mostly off-screen.
        if let remembered = rememberedFrame,
            Monitors.cgFrame(of: screen).intersects(remembered)
        {
            setFrame(windowID: id, remembered)
        } else {
            // First summon: top strip of the visible frame, full width, at
            // the configured height. AX speaks top-left coordinates.
            let visible = screen.visibleFrame
            let height = visible.height * config.dropdown.height
            let topLeftY = Monitors.primaryTop - visible.maxY
            setFrame(
                windowID: id,
                CGRect(
                    x: visible.minX, y: topLeftY, width: visible.width, height: height))
        }
        _ = try? cli.run(["focus", "--window-id", "\(id)"])
    }

    /// AX frame write, bridged from a CGWindowID by position match — the
    /// same CG↔AX bridge the parked-window probe used.
    private static func setFrame(windowID: UInt32, _ frame: CGRect) {
        guard let current = WindowSnapshot.frame(of: windowID),
            let pid = WindowSnapshot.ownerPID(of: windowID)
        else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return }
        for axWindow in windows {
            var positionValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                let positionValue
            else { continue }
            var position = CGPoint.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
            guard abs(position.x - current.minX) <= 2, abs(position.y - current.minY) <= 2
            else { continue }
            var origin = frame.origin
            var size = frame.size
            if let axPoint = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(
                    axWindow, kAXPositionAttribute as CFString, axPoint)
            }
            if let axSize = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
            }
            return
        }
    }

    private static func installedTerminal() -> String? {
        terminals.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }
}
