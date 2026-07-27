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
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "org.alacritty",
        "net.kovidgoyal.kitty", "com.apple.Terminal",
    ]

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
        // Is a window of the app already on the focused workspace? Then this
        // press means "away with it".
        if let listing = try? cli.run([
            "list-windows", "--workspace", focusedWorkspace, "--format",
            "%{window-id}|%{app-bundle-id}",
        ]),
            let line = listing.split(separator: "\n").first(where: {
                $0.hasSuffix("|\(appID)")
            }),
            let id = UInt32(line.split(separator: "|")[0])
        {
            DragLog.log("dropdown: dismissing \(appID)")
            _ = try? cli.run(["move-node-to-workspace", "--window-id", "\(id)", "S"])
            return
        }
        // Summon: find any window of the app anywhere; launch if none.
        if let id = windowID(of: appID, cli: cli) {
            summon(id: id, appID: appID, to: focusedWorkspace, config: config, cli: cli)
        } else {
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
        // Top strip of the visible frame, full width.
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = visible.height * config.dropdown.height
        // AX speaks top-left coordinates.
        let topLeftY = screen.frame.height - visible.maxY
        setFrame(
            windowID: id,
            CGRect(x: visible.minX, y: topLeftY, width: visible.width, height: height))
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
