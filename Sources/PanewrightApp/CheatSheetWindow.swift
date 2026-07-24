import AppKit
import PanewrightCore
import SwiftUI

/// The $mod+? cheat sheet: every binding in the user's actual config (not a
/// hardcoded default set), plus the mouse and bar interactions that have no
/// key. Rendered live from the parsed config so custom keymaps show the truth.
struct CheatSheetView: View {
    let config: PanewrightConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                keySections
                mouseSection
                barSection
            }
            .padding(24)
        }
        .frame(width: 640, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Panewright Cheat Sheet").font(.title2).bold()
            Text(modifierDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var modifierDescription: String {
        switch config.modifier {
        case .leader:
            "Leader style: tap \(prettyKey(config.leaderKey)), release, then press the key below."
        case .hyper:
            "$mod is Caps Lock (hyper, via Karabiner). Hold it with the key below."
        default:
            "$mod is \(prettyChord(config.modifier.rawValue)). Hold it with the key below."
        }
    }

    private var keySections: some View {
        let groups = Dictionary(grouping: config.bindings, by: { category(of: $0.actions) })
        return ForEach(Category.allCases, id: \.self) { cat in
            if let bindings = groups[cat], !bindings.isEmpty {
                section(cat.rawValue) {
                    ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                        row(prettyKey(binding.key), describe(binding.actions))
                    }
                    if cat == .modes {
                        ForEach(config.modes, id: \.name) { mode in
                            ForEach(Array(mode.bindings.enumerated()), id: \.offset) { _, b in
                                row(
                                    "\(mode.name) → \(prettyKey(b.key))",
                                    describe(b.actions))
                            }
                        }
                    }
                }
            }
        }
    }

    private var mouseSection: some View {
        section("Drag-to-tile (mouse)") {
            row("Drag a title bar", "Ghost drag — the window doesn't move until you drop")
            row("Drop on a window's center", "Swap places")
            row("Drop on a window's edge", "Split that cell and take the half")
            row("Drop on a bar number", "Send the window to that workspace")
            row("Drop on empty bar space", "Park the window as a pill")
            row("Drop on nothing", "Cancel — layout unchanged")
        }
    }

    private var barSection: some View {
        section("Status bar") {
            row("M1 M2 M3", "Each bar's badge names its monitor (primary is M1)")
            row("Click a workspace number", "Switch that monitor to it")
            row("Numbers show per monitor", "Only workspaces living on that display; empty ones hide")
            row("[RESIZE] [JOIN] badge", "You're in a mode; Esc exits")
            row("Click a to-do pill", "Edit or resolve the task")
            row("Click a window pill ▸", "Peek the parked window; right-click releases it")
        }
    }

    // MARK: building blocks

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .kerning(1)
            VStack(alignment: .leading, spacing: 3, content: rows)
        }
    }

    private func row(_ key: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 190, alignment: .trailing)
            Text(what).font(.callout)
            Spacer(minLength: 0)
        }
    }

    // MARK: describing the config

    private enum Category: String, CaseIterable {
        case workspaces = "Workspaces"
        case windows = "Windows & focus"
        case layout = "Layout"
        case tools = "Scratchpad & tools"
        case modes = "Modes"
    }

    private func category(of actions: [PanewrightConfig.Action]) -> Category {
        switch actions.first {
        case .workspace, .moveToWorkspace, .workspaceBackAndForth: .workspaces
        case .focus, .move, .focusMonitor, .moveToMonitor, .close: .windows
        case .layoutTiles, .layoutAccordion, .fullscreen, .toggleFloating,
            .joinWith, .flattenWorkspace, .resize: .layout
        case .enterMode: .modes
        default: .tools
        }
    }

    private func describe(_ actions: [PanewrightConfig.Action]) -> String {
        actions.map(describe).joined(separator: ", then ")
    }

    private func describe(_ action: PanewrightConfig.Action) -> String {
        switch action {
        case .workspace(let n):
            "Go to workspace \(n) (summons it to this monitor)"
        case .moveToWorkspace(let n): "Move window to workspace \(n)"
        case .workspaceBackAndForth: "Bounce to the previous workspace"
        case .focus(let d): "Focus \(d.rawValue)"
        case .move(let d): "Move window \(d.rawValue)"
        case .layoutTiles: "Tiles layout"
        case .layoutAccordion: "Accordion (stacked) layout"
        case .fullscreen: "Toggle fullscreen"
        case .toggleFloating: "Toggle floating"
        case .focusMonitor(let t): "Focus monitor \(t.rawValue)"
        case .moveToMonitor(let t): "Move window to monitor \(t.rawValue)"
        case .resize(let dim, let delta):
            "Resize \(dim.rawValue) \(delta >= 0 ? "+" : "")\(delta)"
        case .joinWith(let d): "Join with the \(d.rawValue) neighbor"
        case .flattenWorkspace: "Flatten the workspace tree"
        case .enterMode(let name): "Enter \(name) mode"
        case .exec(let cmd): "Run: \(cmd)"
        case .close: "Close window"
        case .scratchpadShow: "Summon scratchpad"
        case .scratchpadMove: "Stash to scratchpad"
        case .todoAdd: "New to-do"
        case .pillWindow: "Park window as a bar pill"
        case .help: "This cheat sheet"
        }
    }

    /// "shift-h" → "⇧H", "shift-slash" → "?", "minus" → "−", "tab" → "⇥".
    private func prettyKey(_ key: String) -> String {
        let shifted = key.hasPrefix("shift-")
        let base = shifted ? String(key.dropFirst(6)) : key
        let named: [String: String] = [
            "slash": shifted ? "?" : "/", "minus": "−", "equal": "=",
            "tab": "⇥", "enter": "⏎", "space": "Space", "esc": "Esc",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
            "backtick": "`", "comma": ",", "period": ".", "semicolon": ";",
            "quote": "'",
        ]
        if base == "slash", shifted { return "?" }
        let display = named[base] ?? base.uppercased()
        return (shifted && named[base] == nil ? "⇧" : "") + display
    }

    /// "ctrl-cmd" → "⌃⌘", "cmd-backtick" → "⌘`".
    private func prettyChord(_ chord: String) -> String {
        chord.split(separator: "-").map { part in
            switch part {
            case "ctrl": "⌃"
            case "cmd": "⌘"
            case "alt": "⌥"
            case "shift": "⇧"
            default: prettyKey(String(part))
            }
        }.joined()
    }
}

@MainActor
final class CheatSheetWindowController {
    private var window: NSWindow?

    func show(config: PanewrightConfig) {
        // Rebuild each show so a changed config renders fresh.
        let hosting = NSHostingController(rootView: CheatSheetView(config: config))
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Cheat Sheet"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
