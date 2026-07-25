import AppKit
import PanewrightCore
import SwiftUI

/// The widgets picker: everything the bar can show, grouped by category, with
/// what each one displays and a live example — so widgets can be compared side
/// by side instead of discovered one config key at a time. The Order tab is
/// where their left-to-right arrangement is set by dragging.
struct WidgetsView: View {
    @State private var modules: PanewrightConfig.Modules
    @State private var integrations: IntegrationsConfig
    @State private var todoEnabled: Bool
    @State private var pillsEnabled: Bool
    @State private var tab = Tab.available
    /// Companions (to-dos, window pills) build their own bar items, so they
    /// come back separately from the driver-polled widgets.
    let onChange: (PanewrightConfig.Modules, IntegrationsConfig, Bool, Bool) -> Void

    enum Tab: String, CaseIterable { case available = "Available", order = "Order" }

    init(
        modules: PanewrightConfig.Modules,
        integrations: IntegrationsConfig,
        todoEnabled: Bool,
        pillsEnabled: Bool,
        onChange: @escaping (PanewrightConfig.Modules, IntegrationsConfig, Bool, Bool) -> Void
    ) {
        _modules = State(initialValue: modules)
        _integrations = State(initialValue: integrations)
        _todoEnabled = State(initialValue: todoEnabled)
        _pillsEnabled = State(initialValue: pillsEnabled)
        self.onChange = onChange
    }

    /// What each widget puts in the bar — the reason to pick one.
    private static let blurbs: [String: (what: String, example: String)] = [
        "system-monitor": ("CPU and memory with live graphs; click for a mini-htop panel", "CPU 18%  MEM 39%"),
        "system-graphs": ("Live sparklines beside the readout — see a spike building, not just its current value", "▁▃▅▇▅▃"),
        "network": ("Download and upload rate on the active interface", "↓1.2M ↑340K"),
        "ports": ("How many ports are listening; click for the list and what owns them", "⇄ 8"),
        "disk": ("Boot volume used and free", "SSD 2% · 1057G free"),
        "battery": ("Charge and time remaining — what the menu bar hides", "⚡84% · 9:24"),
        "docker": ("Running containers (hidden when Docker isn't installed)", "⬢ 3"),
        "cloud-context": ("kubectl context and AWS profile, highlighted when it looks like production", "prod-west · aws:staging"),
        "scratchpad": ("How many windows are stashed away", "⇩ 2"),
        "mic-mute": ("Microphone live or muted; click to toggle", "🎤"),
        "volume": ("Output volume; click to mute", "🔊 69%"),
        "brew-updates": ("Outdated Homebrew packages", "⬆ 21"),
        "vpn": ("Shows when a VPN tunnel is carrying traffic", "VPN"),
        "keyboard-layout": ("Active input source", "U.S."),
        "focus-mode": ("Shows when a macOS Focus is silencing notifications", "🌙"),
        "now-playing": ("Track from Spotify or Music; click to play/pause", "♪ Kind of Blue — Miles Davis"),
        "weather": ("Current conditions, refreshed hourly", "☀️ 79°F"),
    ]

    /// Work-tracker services are widgets too — same bar, same picker. They
    /// carry credentials, so they keep their own config section.
    private static let workWidgets:
        [(name: String, what: String, example: String, path: WritableKeyPath<IntegrationsConfig, Bool>)] = [
            ("GitHub", "Pull requests awaiting your review, plus your own open PRs", "PR 4", \.github.enabled),
            ("GitLab", "Merge requests you opened or were assigned, with pipeline status", "MR 2", \.gitlab.enabled),
            ("Jira", "Unresolved issues assigned to you", "JIRA 41", \.jira.enabled),
            ("Confluence", "Wiki activity and favorites", "WIKI 2", \.confluence.enabled),
            ("Microsoft Teams", "Your next meeting; click to join", "MTG Standup · 12m", \.teams.enabled),
        ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            Divider()
            if tab == .available { availableList } else { orderList }
            Divider()
            footer
        }
        .frame(width: 580, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Widgets").font(.title2).bold()
            Text("Everything the bar can show. Changes take effect immediately.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var availableList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(PanewrightConfig.Modules.categories, id: \.self) { category in
                    let entries = PanewrightConfig.Modules.catalog.filter { $0.category == category }
                    if !entries.isEmpty {
                        sectionHeader(category)
                        ForEach(entries, id: \.key) { entry in
                            row(
                                name: entry.name,
                                blurb: Self.blurbs[entry.key],
                                isOn: Binding(
                                    get: { modules[keyPath: entry.path] },
                                    set: { modules[keyPath: entry.path] = $0; push() }))
                        }
                    }
                }
                sectionHeader("Companions")
                row(
                    name: "To-do List",
                    blurb: ("Tasks as pills with a + button; click one to edit or resolve it", "Ship 0.3 release  +"),
                    isOn: Binding(get: { todoEnabled }, set: { todoEnabled = $0; push() }))
                row(
                    name: "Window Pills",
                    blurb: ("Park a window in the bar; click to peek, right-click to release", "▸ Slack"),
                    isOn: Binding(get: { pillsEnabled }, set: { pillsEnabled = $0; push() }))

                sectionHeader("Work")
                ForEach(Self.workWidgets, id: \.name) { item in
                    row(
                        name: item.name,
                        blurb: (item.what, item.example),
                        isOn: Binding(
                            get: { integrations[keyPath: item.path] },
                            set: { integrations[keyPath: item.path] = $0; push() }))
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// Drag to arrange; the list reads left to right as the bar does.
    private var orderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Drag to arrange. The top of this list is the leftmost widget in the bar.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 6)
            List {
                ForEach(modules.resolvedOrder, id: \.self) { key in
                    if let entry = PanewrightConfig.Modules.catalog.first(where: { $0.key == key }) {
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary).font(.system(size: 11))
                            Text(entry.name)
                                .font(.system(size: 13))
                                .foregroundStyle(modules[keyPath: entry.path] ? .primary : .tertiary)
                            Spacer()
                            if !modules[keyPath: entry.path] {
                                Text("off").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .onMove { source, destination in
                    var current = modules.resolvedOrder
                    current.move(fromOffsets: source, toOffset: destination)
                    modules.order = current
                    push()
                }
            }
            .listStyle(.inset)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .kerning(0.8)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func row(
        name: String, blurb: (what: String, example: String)?, isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if let blurb {
                        Text(blurb.what)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let blurb {
                    Text(blurb.example)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack {
            Text("Right-click any widget in the bar to turn it off.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Turn All Off") {
                for entry in PanewrightConfig.Modules.catalog {
                    modules[keyPath: entry.path] = false
                }
                push()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func push() { onChange(modules, integrations, todoEnabled, pillsEnabled) }
}

@MainActor
final class WidgetsWindowController {
    private var window: NSWindow?

    func show(
        modules: PanewrightConfig.Modules,
        integrations: IntegrationsConfig,
        todoEnabled: Bool,
        pillsEnabled: Bool,
        onChange: @escaping (PanewrightConfig.Modules, IntegrationsConfig, Bool, Bool) -> Void
    ) {
        let hosting = NSHostingController(
            rootView: WidgetsView(
                modules: modules, integrations: integrations,
                todoEnabled: todoEnabled, pillsEnabled: pillsEnabled, onChange: onChange))
        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Widgets"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
