import AppKit
import PanewrightCore

/// Bridges AeroSpace's monitors to AppKit's screens.
///
/// AeroSpace exposes no geometry — `list-monitors` is an id and a name, full
/// stop — while NSScreen has geometry but no workspace knowledge. Every
/// multi-monitor decision needs both halves, so this joins them on the
/// monitor's name (the only field they share).
///
/// Two identical displays produce duplicate names; those are paired off in
/// order (AeroSpace id ascending against NSScreen.screens order), which is a
/// guess, but a stable one — and with identical panels the cost of pairing
/// them backwards is nil for fitting purposes: the geometry is the same.
@MainActor
enum Monitors {
    struct VisibleWorkspace {
        let workspace: String
        let monitorID: Int
        let screen: NSScreen
    }

    /// One entry per monitor: the workspace currently showing on it, and the
    /// NSScreen it lives on. Monitors whose name matches no screen (a display
    /// mid-disconnect) are omitted — better no fitting than fitting against
    /// the wrong glass.
    static func visibleWorkspaces(cli: AeroSpaceCLI) -> [VisibleWorkspace] {
        guard
            let output = try? cli.run([
                "list-workspaces", "--monitor", "all", "--visible",
                "--format", "%{workspace}|%{monitor-id}|%{monitor-name}",
            ])
        else { return [] }
        var claimed: Set<Int> = []  // NSScreen indices already paired off
        var result: [VisibleWorkspace] = []
        let screens = NSScreen.screens
        let rows: [(workspace: String, monitor: Int, name: String)] = output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count >= 3, let id = Int(parts[1]) else { return nil }
                return (parts[0], id, normalize(parts[2]))
            }
            .sorted { $0.monitor < $1.monitor }
        for row in rows {
            guard
                let index = screens.indices.first(where: {
                    !claimed.contains($0) && normalize(screens[$0].localizedName) == row.name
                })
            else { continue }
            claimed.insert(index)
            result.append(
                VisibleWorkspace(
                    workspace: row.workspace, monitorID: row.monitor, screen: screens[index]))
        }
        return result
    }

    /// The screen of the monitor holding the focused workspace — where i3
    /// would put anything that "appears": the palette, the overview, a toast,
    /// the dropdown. Falls back to the screen under the mouse, then main.
    static func focusedScreen() -> NSScreen? {
        if let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-workspaces", "--focused", "--format", "%{monitor-name}",
            ]),
            let name = output.split(separator: "\n").first.map({
                normalize($0.trimmingCharacters(in: .whitespaces))
            }),
            let screen = NSScreen.screens.first(where: { normalize($0.localizedName) == name })
        {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// A screen's frame in CGWindowList/AX top-left coordinates.
    ///
    /// CG's global origin is the top-*left of the primary display* — not of
    /// the arrangement's bounding box — so the flip constant is the primary
    /// screen's Cocoa top, the same for every screen. (Verified against
    /// CGDisplayBounds: a portrait external at Cocoa (1728, 0, 2160, 3840)
    /// beside a 1117pt-tall primary reports CG y = 1117 − 3840 = −2723.)
    static func cgFrame(of screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
            width: screen.frame.width, height: screen.frame.height)
    }

    /// The primary display's Cocoa maxY — the flip constant between Cocoa's
    /// bottom-left and CG's top-left coordinate systems.
    static var primaryTop: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.maxY ?? 0
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
