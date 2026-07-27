import AppKit
import PanewrightCore
import SwiftUI

/// The `$mod+d` fuzzy palette — dmenu for this desktop. One text field, one
/// ranked list, three sources: open windows (jump), installed apps (launch),
/// Panewright commands (run). Keyboard-only by design: type, arrows, return;
/// escape or focus loss closes it.
@MainActor
final class PaletteController {
    static let shared = PaletteController()
    private var panel: NSPanel?
    private var model = PaletteModel()

    func toggle() {
        if let panel, panel.isVisible {
            close()
            return
        }
        open()
    }

    private func open() {
        model.reload()
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            // Nonactivating: the palette takes keystrokes without activating
            // Panewright, so dismissing it returns focus to whatever had it —
            // the launcher contract every dmenu user expects.
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(
                rootView: PaletteView(model: model, dismiss: { [weak self] in self?.close() }))
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - 280,
                    y: frame.maxY - 380 - frame.height * 0.18))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        model.query = ""
    }
}

/// One row the palette can act on.
struct PaletteItem: Identifiable {
    enum Kind {
        case window(id: UInt32, workspace: String)
        case app(url: URL)
        case command(() -> Void)
    }

    let id = UUID()
    let title: String
    let subtitle: String
    let icon: NSImage?
    let kind: Kind
}

@MainActor @Observable
final class PaletteModel {
    var query = "" {
        didSet { rerank() }
    }
    var ranked: [PaletteItem] = []
    var selected = 0
    private var all: [PaletteItem] = []

    func reload() {
        var items: [PaletteItem] = []
        // Open windows first — jumping beats launching on ties.
        if let cli = AeroSpaceCLI.locate(),
            let output = try? cli.run([
                "list-windows", "--all", "--format",
                "%{window-id}|%{workspace}|%{app-pid}|%{app-name}|%{window-title}",
            ])
        {
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 4)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 4, let id = UInt32(parts[0]) else { continue }
                let pid = Int32(parts[2]) ?? 0
                let icon = NSRunningApplication(processIdentifier: pid)?.icon
                let title = parts.count == 5 && !parts[4].isEmpty ? parts[4] : parts[3]
                items.append(
                    PaletteItem(
                        title: title,
                        subtitle: "\(parts[3]) · workspace \(parts[1])",
                        icon: icon,
                        kind: .window(id: id, workspace: parts[1])))
            }
        }
        items.append(contentsOf: Self.installedApps())
        items.append(contentsOf: Self.commands())
        all = items
        rerank()
    }

    private func rerank() {
        ranked = Array(PaletteScore.rank(query: query, in: all, by: \.title).prefix(12))
        selected = 0
    }

    func run(_ item: PaletteItem) {
        switch item.kind {
        case .window(let id, _):
            _ = try? AeroSpaceCLI.locate()?.run(["focus", "--window-id", "\(id)"])
        case .app(let url):
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        case .command(let action):
            action()
        }
    }

    private static func installedApps() -> [PaletteItem] {
        var items: [PaletteItem] = []
        let roots = [
            "/Applications", "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        for root in roots {
            guard
                let names = try? FileManager.default.contentsOfDirectory(atPath: root)
            else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = root + "/" + name
                items.append(
                    PaletteItem(
                        title: String(name.dropLast(4)),
                        subtitle: "Launch",
                        icon: NSWorkspace.shared.icon(forFile: path),
                        kind: .app(url: URL(filePath: path))))
            }
        }
        return items
    }

    private static func commands() -> [PaletteItem] {
        func cli(_ args: [String]) -> () -> Void {
            { _ = try? AeroSpaceCLI.locate()?.run(args) }
        }
        func link(_ url: String) -> () -> Void {
            { NSWorkspace.shared.open(URL(string: url)!) }
        }
        var items: [PaletteItem] = (0...9).map { n in
            PaletteItem(
                title: "Workspace \(n)", subtitle: "Panewright command", icon: nil,
                kind: .command(cli(["workspace", "\(n)"])))
        }
        let rest: [(String, () -> Void)] = [
            ("Fullscreen", cli(["fullscreen"])),
            ("Float / Tile Window", cli(["layout", "floating", "tiling"])),
            ("Flatten Workspace", cli(["flatten-workspace-tree"])),
            ("Balance Sizes", cli(["balance-sizes"])),
            ("Settings", link("panewright://settings")),
            ("Cheat Sheet", link("panewright://help")),
            ("Widgets", link("panewright://settings/widgets")),
        ]
        items.append(
            contentsOf: rest.map {
                PaletteItem(
                    title: $0.0, subtitle: "Panewright command", icon: nil,
                    kind: .command($0.1))
            })
        return items
    }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Windows, apps, commands…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .light))
                .padding(14)
                .focused($focused)
                .onSubmit {
                    if model.ranked.indices.contains(model.selected) {
                        model.run(model.ranked[model.selected])
                        dismiss()
                    }
                }
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.ranked.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            if let icon = item.icon {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "command")
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text(item.subtitle)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            index == model.selected
                                ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.run(item)
                            dismiss()
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) {
            model.selected = min(model.selected + 1, model.ranked.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.selected = max(model.selected - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }
}
