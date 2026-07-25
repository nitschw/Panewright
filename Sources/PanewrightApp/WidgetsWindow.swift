import AppKit
import PanewrightCore
import SwiftUI

/// The widgets picker: every available widget in one list with a checkbox and
/// a line on what it shows, so they can be compared side by side rather than
/// discovered one config key at a time.
struct WidgetsView: View {
    @State private var modules: PanewrightConfig.Modules
    let onChange: (PanewrightConfig.Modules) -> Void

    init(modules: PanewrightConfig.Modules, onChange: @escaping (PanewrightConfig.Modules) -> Void) {
        _modules = State(initialValue: modules)
        self.onChange = onChange
    }

    /// What each widget puts in the bar — the reason to pick one.
    private static let blurbs: [String: (what: String, example: String)] = [
        "system-monitor": ("CPU and memory with live graphs; click for a mini-htop panel", "CPU 18%  MEM 39%"),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Widgets").font(.title2).bold()
                Text("Everything the bar can show. Toggling takes effect immediately.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(PanewrightConfig.Modules.catalog.enumerated()), id: \.element.key) {
                        index, entry in
                        let blurb = Self.blurbs[entry.key]
                        Toggle(isOn: binding(for: entry.path)) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.system(size: 13, weight: .semibold))
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
                        .padding(.vertical, 9)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                }
            }

            Divider()
            HStack {
                Text("Right-click any widget in the bar to turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Turn All Off") {
                    for entry in PanewrightConfig.Modules.catalog {
                        modules[keyPath: entry.path] = false
                    }
                    onChange(modules)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
    }

    private func binding(for path: WritableKeyPath<PanewrightConfig.Modules, Bool>) -> Binding<Bool> {
        Binding(
            get: { modules[keyPath: path] },
            set: {
                modules[keyPath: path] = $0
                onChange(modules)
            })
    }
}

@MainActor
final class WidgetsWindowController {
    private var window: NSWindow?

    func show(modules: PanewrightConfig.Modules, onChange: @escaping (PanewrightConfig.Modules) -> Void) {
        let hosting = NSHostingController(
            rootView: WidgetsView(modules: modules, onChange: onChange))
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
