import AppKit
import PanewrightCore
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modifierSection
                    Divider()
                    gapsSection
                    Divider()
                    borderSection
                    Divider()
                    barSection
                    Divider()
                    floatingAppsSection
                    Divider()
                    integrationsSection
                    Divider()
                    bindingsSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
    }

    // MARK: Sections

    private var modifierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mod Key").font(.headline)
            Picker("Style", selection: bind(\.modifier)) {
                Text("Hyper (Caps Lock via Karabiner)").tag(PanewrightConfig.Modifier.hyper)
                Text("Option").tag(PanewrightConfig.Modifier.alt)
                Text("Command").tag(PanewrightConfig.Modifier.cmd)
                Text("Control (pairs with Caps Lock → Control)")
                    .tag(PanewrightConfig.Modifier.ctrl)
                Text("Ctrl+Option").tag(PanewrightConfig.Modifier.ctrlAlt)
                Text("Ctrl+Command").tag(PanewrightConfig.Modifier.ctrlCmd)
                Text("Leader key (tmux-style prefix)").tag(PanewrightConfig.Modifier.leader)
            }
            .labelsHidden()
            if model.config.modifier == .leader {
                TextField("Leader key (AeroSpace syntax)", text: bind(\.leaderKey))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Toggle("Focus follows mouse (hover to focus, no click)", isOn: bind(\.focusFollowsMouse))
        }
    }

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gaps").font(.headline)
            intSlider("Inner", value: bind(\.gaps.inner), range: 0...40)
            intSlider("Outer", value: bind(\.gaps.outer), range: 0...40)
            Text("Drag the sliders — windows follow live.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var borderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bind(\.focusBorder.enabled)) {
                Text("Focus Border").font(.headline)
            }
            if model.config.focusBorder.enabled {
                intSlider("Width", value: bind(\.focusBorder.width), range: 1...12)
                colorRow("Active", hex: bind(\.focusBorder.activeColor))
                colorRow("Inactive", hex: bind(\.focusBorder.inactiveColor))
            }
        }
    }

    private var barSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bind(\.statusBar.enabled)) {
                Text("Status Bar").font(.headline)
            }
            if model.config.statusBar.enabled {
                Picker("Theme", selection: bind(\.statusBar.theme)) {
                    Text("Native (vibrancy, SF Pro)").tag(PanewrightConfig.StatusBar.Theme.native)
                    Text("Technical (square, monospace)")
                        .tag(PanewrightConfig.StatusBar.Theme.technical)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var floatingAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Always-Floating Apps").font(.headline)
            Text("Bundle IDs of apps that float instead of tiling.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.config.floatingApps.indices, id: \.self) { index in
                HStack {
                    TextField(
                        "com.example.app",
                        text: Binding(
                            get: { model.config.floatingApps[index] },
                            set: {
                                model.config.floatingApps[index] = $0
                                model.configChanged()
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        model.config.floatingApps.remove(at: index)
                        model.configChanged()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add App") {
                model.config.floatingApps.append("")
            }
        }
    }

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Integrations").font(.headline)
            Text("Work items in your status bar. Tokens go to your Keychain, never the config file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            IntegrationRow(
                name: "GitHub", service: "github",
                service_: bind(\.integrations.github),
                hostPlaceholder: "github.example.com (blank = github.com)",
                userLabel: nil,
                note: "Falls back to your gh CLI token when none is set.")
            IntegrationRow(
                name: "GitLab", service: "gitlab",
                service_: bind(\.integrations.gitlab),
                hostPlaceholder: "gitlab.example.com",
                userLabel: nil,
                note: "Merge requests you opened or were assigned, with pipeline status.")
            IntegrationRow(
                name: "Jira", service: "jira",
                service_: bind(\.integrations.jira),
                hostPlaceholder: "company.atlassian.net",
                userLabel: "Email",
                note: "Cloud uses email + API token; Server/DC uses a bearer PAT (leave email blank).")
            IntegrationRow(
                name: "Bitbucket", service: "bitbucket",
                service_: bind(\.integrations.bitbucket),
                hostPlaceholder: "bitbucket.org",
                userLabel: "Username",
                note: "Settings are saved; the provider ships in a later release.")
            IntegrationRow(
                name: "Confluence", service: "confluence",
                service_: bind(\.integrations.confluence),
                hostPlaceholder: "company.atlassian.net",
                userLabel: "Email",
                note: "Settings are saved; search and the reader ship in a later release.")
        }
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keybindings").font(.headline)
            Text("Key (e.g. \"1\", \"shift-h\") and an i3-flavored action (chains with \";\").")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($model.bindingRows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("key", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .onSubmit { model.bindingRowsChanged() }
                        TextField("action", text: $row.action)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.bindingRowsChanged() }
                        Button(role: .destructive) {
                            model.bindingRows.removeAll { $0.id == row.id }
                            model.bindingRowsChanged()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    if let error = model.bindingErrors[row.id] {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Button("Add Binding") {
                model.bindingRows.append(.init(key: "", action: ""))
            }
            Text("Press Return in a field to apply binding edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Reload From File") {
                model.reloadFromDisk()
            }
            Button("Save as Profile…") {
                model.saveAsProfile()
            }
        }
        .padding(12)
    }

    // MARK: Binding helpers

    private func bind<T>(_ keyPath: WritableKeyPath<PanewrightConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: {
                model.config[keyPath: keyPath] = $0
                model.configChanged()
            })
    }

    private func intSlider(
        _ label: String, value: Binding<Int>, range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ), in: range)
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(cssHex: hex.wrappedValue) ?? .accentColor },
                    set: { hex.wrappedValue = $0.cssHexString }
                ),
                supportsOpacity: true)
            .labelsHidden()
            Text(hex.wrappedValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// One service: enable it, point it at a host, and stash its token.
private struct IntegrationRow: View {
    let name: String
    let service: String
    @Binding var service_: IntegrationsConfig.Service
    let hostPlaceholder: String
    let userLabel: String?
    let note: String
    @State private var hasToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(name, isOn: $service_.enabled)
                .font(.callout.weight(.medium))
            if service_.enabled {
                HStack {
                    Text("Host").frame(width: 46, alignment: .leading)
                    TextField(hostPlaceholder, text: $service_.host)
                        .textFieldStyle(.roundedBorder)
                }
                if let userLabel {
                    HStack {
                        Text(userLabel).frame(width: 46, alignment: .leading)
                        TextField("", text: $service_.user)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Text("Token").frame(width: 46, alignment: .leading)
                    Button(hasToken ? "Token saved — replace…" : "Set token…") {
                        TokenPrompt.ask(service: service, displayName: name)
                        hasToken = Keychain.hasToken(for: service)
                    }
                    if hasToken {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { hasToken = Keychain.hasToken(for: service) }
    }
}

extension Color {
    init?(cssHex: String) {
        guard let argb = try? ColorHex.argb(fromCSSHex: cssHex) else { return nil }
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255)
    }

    var cssHexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
