import AppKit
import PanewrightCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var tab = Tab.general

    /// Everything the config file can express, grouped by what you'd be
    /// thinking about when you came looking for it. One long scroll made the
    /// rarely-touched settings (hooks, workspace pinning) impossible to find,
    /// which is why they were never added to the GUI at all.
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case keys = "Keybindings"
        case layout = "Layout"
        case appearance = "Appearance"
        case scripting = "Scripting"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .keys: "keyboard"
            case .layout: "square.grid.2x2"
            case .appearance: "paintpalette"
            case .scripting: "curlybraces"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    sections
                }
                // A caller sent the user here to fix one specific thing —
                // switch to the tab holding it, then scroll it into view.
                // Scrolling to something on a hidden tab would look like
                // nothing happened at all.
                .onChange(of: model.revealed) { _, target in
                    guard let target else { return }
                    tab = self.tab(for: target)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(anchor(for: target), anchor: .center)
                    }
                }
                .onAppear {
                    guard let target = model.revealed else { return }
                    tab = self.tab(for: target)
                    proxy.scrollTo(anchor(for: target), anchor: .center)
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
    }

    /// AnyHashable so one ScrollViewReader can address both the named
    /// sections and the binding rows' UUIDs.
    private func anchor(for target: SettingsModel.Reveal) -> AnyHashable {
        switch target {
        case .modifier: AnyHashable("modifier")
        case .binding(let id): AnyHashable(id)
        case .widgets: AnyHashable("widgets")
        case .layout: AnyHashable("layout")
        case .appearance: AnyHashable("appearance")
        case .keybindings: AnyHashable("keybindings")
        case .scripting: AnyHashable("scripting")
        }
    }

    private func tab(for target: SettingsModel.Reveal) -> Tab {
        switch target {
        case .modifier: .general
        case .binding: .keys
        case .widgets: .appearance
        case .layout: .layout
        case .appearance: .appearance
        case .keybindings: .keys
        case .scripting: .scripting
        }
    }

    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch tab {
            case .general:
                modifierSection.id("modifier")
                Divider()
                fittingSection
            case .keys:
                bindingsSection.id("keybindings")
                Divider()
                modesSection
            case .layout:
                gapsSection.id("layout")
                Divider()
                Toggle(
                    "New windows of already-open apps arrive floating",
                    isOn: bind(\.floatSecondaryWindows))
                Text("Auth prompts and popups are usually an app's second window. Re-tile any keeper with $mod+shift+space.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                floatingAppsSection
                Divider()
                workspaceMonitorsSection
                Divider()
                appWorkspacesSection
            case .scripting:
                hooksSection.id("scripting")
                Divider()
                scriptsSection
            case .appearance:
                borderSection.id("appearance")
                Divider()
                barAppearanceSection
                Divider()
                barMonitorsSection
                Divider()
                widgetsSection.id("widgets")
                Divider()
                companionsSection
                Divider()
                integrationsSection
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                TextField("Leader key (e.g. alt, ctrl-cmd)", text: bind(\.leaderKey))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Toggle("Focus follows mouse (hover to focus, no click)", isOn: bind(\.focusFollowsMouse))
            Toggle(
                "Switching apps follows their windows", isOn: bind(\.followAppSwitch))
            Text(
                "Cmd+Tab to a window parked in the bar summons it; to one on another "
                    + "workspace, goes there."
            )
            .font(.caption).foregroundStyle(.secondary)
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

    /// To-dos and window pills: bar features that aren't widgets, because they
    /// build their own items rather than being polled.
    private var companionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Companions").font(.headline)
            Toggle("To-do List", isOn: bind(\.todo.enabled))
            Text("Tasks as pills with a + button; click one to edit or resolve it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Window Pills", isOn: bind(\.pills.enabled))
            if model.config.pills.enabled {
                Toggle("Drag a window onto the bar to park it", isOn: bind(\.pills.dragToBar))
                    .padding(.leading, 18)
                Text(
                    "$mod+P parks the focused window. Click its pill to peek, "
                        + "right-click to return it to tiling."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Bar theme and accent. `bar.accent-color` was supported by the config
    /// and the emitter but reachable from nothing — you had to hand-write it.
    private var barAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bind(\.statusBar.enabled)) {
                Text("Status Bar").font(.headline)
            }
            Picker("Theme", selection: bind(\.statusBar.theme)) {
                Text("Native (vibrancy, SF Pro)").tag(PanewrightConfig.StatusBar.Theme.native)
                Text("Technical (square, monospace)")
                    .tag(PanewrightConfig.StatusBar.Theme.technical)
            }
            .pickerStyle(.segmented)
            // Top or bottom only: left/right were probed, and SketchyBar
            // silently coerces vertical positions to "top".
            Picker("Edge", selection: bind(\.statusBar.position)) {
                Text("Bottom").tag(PanewrightConfig.StatusBar.Position.bottom)
                Text("Top").tag(PanewrightConfig.StatusBar.Position.top)
            }
            .pickerStyle(.segmented)
            intSlider(
                "Thickness",
                value: Binding(
                    get: { model.config.statusBar.effectiveThickness },
                    set: {
                        model.config.statusBar.thickness = $0
                        model.configChanged()
                    }),
                range: 18...60)
            intSlider(
                "Text size",
                value: Binding(
                    get: { model.config.statusBar.effectiveFontSize },
                    set: {
                        model.config.statusBar.fontSize = $0
                        model.configChanged()
                    }),
                range: 9...24)
            intSlider(
                "Opacity %",
                value: Binding(
                    get: {
                        Int(
                            ((model.config.statusBar.opacity
                                ?? (model.config.statusBar.theme == .native ? 0.17 : 0.94))
                                * 100).rounded())
                    },
                    set: {
                        model.config.statusBar.opacity = Double($0) / 100
                        model.configChanged()
                    }),
                range: 0...100)
            Toggle("Show over fullscreen apps", isOn: bind(\.statusBar.showInFullscreen))
            Toggle("Auto-hide (reveal on mouseover)", isOn: bind(\.statusBar.autoHide))
            if model.config.statusBar.autoHide {
                intSlider(
                    "Hide after",
                    value: Binding(
                        get: { Int(model.config.statusBar.autoHideDelay) },
                        set: {
                            model.config.statusBar.autoHideDelay = Double($0)
                            model.configChanged()
                        }),
                    range: 1...30)
                Text("Windows use the bar's strip while it's hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(
                "Use a separate accent color for the bar",
                isOn: Binding(
                    get: { model.config.statusBar.accentColor != nil },
                    set: { on in
                        // Defaults to the focus border's color, which is the
                        // behavior when this is unset — so switching it on
                        // changes nothing until you pick something.
                        model.config.statusBar.accentColor =
                            on ? model.config.focusBorder.activeColor : nil
                        model.configChanged()
                    }))
            if model.config.statusBar.accentColor != nil {
                colorRow(
                    "Accent",
                    hex: Binding(
                        get: { model.config.statusBar.accentColor ?? "" },
                        set: {
                            model.config.statusBar.accentColor = $0
                            model.configChanged()
                        }))
            } else {
                Text("Follows the focus border color — one accent for the whole system.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// [[bar.monitor]] rules: which widget chips each display carries.
    private var barMonitorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bar per monitor").font(.headline)
            Text("With no rules, the main display carries the widget chips and every other display shows a clean workspace strip. Rules match top-down, first match wins. Match a display by part of its name (\u{201C}LC32G7\u{201D}) or a class: builtin, external, portrait, landscape, main, or * for everything.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($model.barMonitorRows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("builtin, portrait, name…", text: $row.match)
                            .frame(width: 170)
                            .onChange(of: row.match) { model.barMonitorRowsChanged() }
                        Picker("", selection: $row.mode) {
                            ForEach(SettingsModel.BarMonitorRow.WidgetMode.allCases, id: \.self) {
                                Text($0.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .onChange(of: row.mode) { model.barMonitorRowsChanged() }
                        Toggle("No bar", isOn: $row.hidden)
                            .onChange(of: row.hidden) { model.barMonitorRowsChanged() }
                        Spacer()
                        Button {
                            model.barMonitorRows.removeAll { $0.id == row.id }
                            model.barMonitorRowsChanged()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    if row.mode == .custom {
                        TextField(
                            "battery, network, todo…", text: $row.widgets
                        )
                        .onChange(of: row.widgets) { model.barMonitorRowsChanged() }
                        Text("Widget names as in the list below, plus todo and integrations.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
            Button("Add Rule") {
                model.barMonitorRows.append(
                    .init(match: "", mode: .all, widgets: "", hidden: false))
            }
        }
    }

    /// Widget toggles and their left-to-right order, driven by the catalog so
    /// a new widget needs no change here.
    private var widgetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Widgets").font(.headline)
            Text("Use the arrows to reorder — the top of the list is the leftmost widget.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.config.modules.resolvedOrder, id: \.self) { key in
                if let entry = PanewrightConfig.Modules.catalog.first(where: { $0.key == key }) {
                    HStack(spacing: 8) {
                        Toggle(
                            entry.name,
                            isOn: Binding(
                                get: { model.config.modules[keyPath: entry.path] },
                                set: {
                                    model.config.modules[keyPath: entry.path] = $0
                                    model.configChanged()
                                }))
                        Spacer()
                        moveButtons(for: key)
                    }
                }
            }
        }
    }

    /// Arrows rather than drag: this list lives inside a ScrollView, where a
    /// nested List with .onMove either can't size itself or steals the scroll.
    private func moveButtons(for key: String) -> some View {
        HStack(spacing: 2) {
            Button {
                move(key, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            Button {
                move(key, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func move(_ key: String, by offset: Int) {
        var order = model.config.modules.resolvedOrder
        guard let index = order.firstIndex(of: key) else { return }
        let destination = index + offset
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        model.config.modules.order = order
        model.configChanged()
    }

    private var fittingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: bind(\.fitting.enabled)) {
                Text("Auto-Fit Windows").font(.headline)
            }
            Text(
                "Some apps refuse to shrink past a minimum size and end up drawing over "
                    + "their neighbor. This shrinks the others to make room."
            )
            .font(.caption).foregroundStyle(.secondary)
            if model.config.fitting.enabled {
                Toggle(
                    "Move a window to another workspace when nothing fits",
                    isOn: bind(\.fitting.overflow))
                Text(
                    model.config.fitting.overflow
                        ? "The newest window moves out, and you get a notification saying so."
                        : "Windows will be left overlapping when no arrangement fits."
                )
                .font(.caption).foregroundStyle(.secondary)
                intSlider("Step", value: bind(\.fitting.step), range: 20...160)
                Text("How much space to reclaim per attempt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep floating windows above tiled ones", isOn: bind(\.fitting.floatOnTop))
            if model.config.fitting.floatOnTop {
                Text("A floating window covered by a tiled one defeats the point of floating it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var workspaceMonitorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace Monitors").font(.headline)
            Text("Pin a workspace to a monitor: main, secondary, a number, or a name pattern.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($model.workspaceMonitorRows) { $row in
                HStack {
                    TextField("1", text: $row.key)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                        .onSubmit { model.workspaceMonitorRowsChanged() }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("main", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.workspaceMonitorRowsChanged() }
                    removeButton {
                        let id = row.id
                        model.workspaceMonitorRows.removeAll { $0.id == id }
                        model.workspaceMonitorRowsChanged()
                    }
                }
            }
            Button("Add Assignment") { model.workspaceMonitorRows.append(.init(key: "", value: "")) }
            Text("Press Return in a field to apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appWorkspacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Workspaces").font(.headline)
            Text("Apps that always open on a given workspace.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($model.appWorkspaceRows) { $row in
                HStack {
                    TextField("com.example.app", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.appWorkspaceRowsChanged() }
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    TextField("3", text: $row.value)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                        .onSubmit { model.appWorkspaceRowsChanged() }
                    removeButton {
                        let id = row.id
                        model.appWorkspaceRows.removeAll { $0.id == id }
                        model.appWorkspaceRowsChanged()
                    }
                }
            }
            Button("Add Assignment") { model.appWorkspaceRows.append(.init(key: "", value: "")) }
            Text("Press Return in a field to apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Modes and their bindings — the one part of the config that most wants a
    /// GUI (bare single keys, no modifiers) and was hand-editing only.
    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modes").font(.headline)
            Text(
                "A mode captures the keyboard until Esc. Keys inside it are bare — "
                    + "no modifier to hold."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach($model.modeRows) { $mode in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("mode name", text: $mode.name)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                            .onSubmit { model.modeRowsChanged() }
                        Spacer()
                        removeButton {
                            let id = mode.id
                            model.modeRows.removeAll { $0.id == id }
                            model.modeRowsChanged()
                        }
                    }
                    ForEach($mode.bindings) { $row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                TextField("key", text: $row.key)
                                    .textFieldStyle(.roundedBorder).frame(width: 90)
                                    .onSubmit { model.modeRowsChanged() }
                                TextField("action", text: $row.action)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { model.modeRowsChanged() }
                                removeButton {
                                    let id = row.id
                                    mode.bindings.removeAll { $0.id == id }
                                    model.modeRowsChanged()
                                }
                            }
                            if let error = model.bindingErrors[row.id] {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Button("Add Key") { mode.bindings.append(.init(key: "", action: "")) }
                        .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
            Button("Add Mode") { model.modeRows.append(.init(name: "", bindings: [])) }
            Text("Press Return in a field to apply.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
    }

    private var floatingAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Always-Floating Apps").font(.headline)
            Text("Bundle IDs of apps that float instead of tiling.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Indexed rows have to be bounds-checked on both sides of a delete:
            // SwiftUI re-evaluates the surviving rows' getters before it
            // rebuilds the ForEach, so the last row briefly reads an index that
            // no longer exists — which is a crash, not a stale value.
            ForEach(model.config.floatingApps.indices, id: \.self) { index in
                HStack {
                    TextField(
                        "com.example.app",
                        text: Binding(
                            get: {
                                index < model.config.floatingApps.count
                                    ? model.config.floatingApps[index] : ""
                            },
                            set: {
                                guard index < model.config.floatingApps.count else { return }
                                model.config.floatingApps[index] = $0
                                model.configChanged()
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        guard index < model.config.floatingApps.count else { return }
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
                name: "Microsoft Teams", service: "teams",
                service_: bind(\.integrations.teams),
                hostPlaceholder: "(blank = commercial cloud)",
                userLabel: nil,
                note: "Your next meeting, with a click-to-join link.")
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
                let conflicts = model.conflicts(for: row.key)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("key", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                            .onSubmit { model.bindingRowsChanged() }
                        if !conflicts.isEmpty {
                            ConflictBadge(conflicts: conflicts)
                        }
                        TextField("action", text: $row.action)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.bindingRowsChanged() }
                        Button(role: .destructive) {
                            let id = row.id
                            model.bindingRows.removeAll { $0.id == id }
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
                .id(row.id)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(model.revealed == .binding(row.id)
                            ? Color.accentColor.opacity(0.18) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(conflicts.isEmpty ? 0 : 0.75), lineWidth: 1))
                .animation(.easeInOut(duration: 0.25), value: model.revealed)
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

    // MARK: Scripting

    /// A hook field with a real explanation: when it fires, what it's for,
    /// and what each environment variable means — "WORKSPACE ·
    /// PREV_WORKSPACE" is a reminder for someone who already knows, not a
    /// description for someone who doesn't.
    private func hookField(
        _ title: String, _ keyPath: WritableKeyPath<PanewrightConfig, String?>,
        fires: String, vars: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(fires).font(.caption).foregroundStyle(.secondary)
            TextField(
                "",
                text: Binding(
                    get: { model.config[keyPath: keyPath] ?? "" },
                    set: {
                        model.config[keyPath: keyPath] = $0.isEmpty ? nil : $0
                        model.configChanged()
                    }),
                prompt: Text("shell command, or path to a script — empty = off"))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(vars, id: \.0) { name, meaning in
                    Text("$\(name)").font(.caption2.monospaced())
                        + Text("  \(meaning)").font(.caption2)
                }
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 6)
    }

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hooks").font(.headline)
            Text("A hook is a shell command Panewright runs for you when something happens on the desktop — the same idea as i3's exec on events. Put a command or a script path in a field and it runs every time that event fires, with details passed as environment variables your script can read.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Try it: paste  say \"workspace $WORKSPACE\"  into the first field, switch workspaces, and your Mac announces them. (Then clear the field.)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            hookField(
                "Workspace changed", \.workspaceChangedHook,
                fires: "Every time you switch workspaces — by key, click, or drag. Good for: per-workspace wallpaper, logging where your time goes, external status displays.",
                vars: [
                    ("WORKSPACE", "the workspace you just landed on"),
                    ("PREV_WORKSPACE", "the one you came from"),
                ])
            hookField(
                "Focus changed", \.focusChangedHook,
                fires: "Every time a different window takes focus. Fires a lot — keep the command fast, and do heavy work in a background job it kicks off. Good for: per-app keyboard layouts, time trackers.",
                vars: [
                    ("FOCUSED_APP", "name of the app that now has focus"),
                    ("FOCUSED_WINDOW_ID", "its window's id (usable with the aerospace CLI)"),
                    ("WORKSPACE", "where that window lives"),
                ])
            hookField(
                "Window opened", \.windowOpenedHook,
                fires: "A new window appeared anywhere, on any workspace. Good for: auto-arranging apps beyond the per-app rules, notifications for long-awaited windows.",
                vars: [
                    ("WINDOW_ID", "the new window's id"),
                    ("APP_NAME", "the app it belongs to"),
                    ("APP_BUNDLE_ID", "that app's bundle identifier"),
                ])
            hookField(
                "Window closed", \.windowClosedHook,
                fires: "A window went away. The variables still describe it — Panewright remembers what it was, even though it's gone.",
                vars: [
                    ("WINDOW_ID", "the closed window's (former) id"),
                    ("APP_NAME", "the app that owned it"),
                    ("APP_BUNDLE_ID", "that app's bundle identifier"),
                ])
            hookField(
                "Mode changed", \.modeChangedHook,
                fires: "You entered or left a binding mode (resize, join, pills — or back to main). Good for: syncing an external keypad or lighting to the current mode.",
                vars: [
                    ("MODE", "the mode just entered: main, resize, join, pills…")
                ])
        }
    }

    private static let userScriptsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".config/panewright/user-scripts")

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Scripts").font(.headline)
            Text("Pickers on the `panewright menu` primitive — lines in, choice out. The built-ins are worked examples; yours live in user-scripts/ (the generated scripts/ folder is overwritten on every apply).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Self.listScripts(), id: \.path) { url in
                HStack {
                    Image(systemName: "scroll")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                    if url.path.contains("/scripts/") {
                        Text("built-in").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Button("New Script from Template…") { Self.newScriptFromTemplate() }
            Text("Creates a commented starter in user-scripts/ and opens it in your editor. Run it from a binding (action = \"exec …\") or the $mod+D palette.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func listScripts() -> [URL] {
        var urls: [URL] = []
        let generated = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/panewright/scripts")
        for dir in [generated, userScriptsDirectory] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.sorted()
            where name.hasPrefix("menu-") || dir == userScriptsDirectory {
                urls.append(dir.appending(path: name))
            }
        }
        return urls
    }

    private static func newScriptFromTemplate() {
        try? FileManager.default.createDirectory(
            at: userScriptsDirectory, withIntermediateDirectories: true)
        var n = 1
        var file = userScriptsDirectory.appending(path: "my-menu.sh")
        while FileManager.default.fileExists(atPath: file.path) {
            n += 1
            file = userScriptsDirectory.appending(path: "my-menu-\(n).sh")
        }
        let template = """
        #!/bin/bash
        # A Panewright menu script — lines in on stdin, the pick on stdout.
        # Bind it:   action = "exec \(file.path)"
        # Or run it from the $mod+D palette by name.

        PICK=$(printf "first option\\nsecond option\\nthird option" \\
          | "$HOME/.config/panewright/bin/panewright" menu "choose:") || exit 0

        case "$PICK" in
          "first option")  say "you picked one" ;;
          "second option") say "you picked two" ;;
          "third option")  say "you picked three" ;;
        esac
        """
        try? (template + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)
        // -t: the user's plain-text editor, never Xcode-by-file-association.
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-t", file.path]
        try? open.run()
        NSWorkspace.shared.activateFileViewerSelecting([file])
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

/// The red flag on a binding that can't do what it says. Hovering explains
/// what it's up against — after a beat, so that sweeping the pointer across
/// the list doesn't strobe popovers at you.
///
/// `.help()` would be the one-liner here, but its delay is the system's
/// (around a second) and not adjustable, and this wants half that.
private struct ConflictBadge: View {
    let conflicts: [BindingConflicts.Conflict]
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .onHover { inside in
                hovering = inside
                guard inside else {
                    showing = false
                    return
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    // Still there half a second later, or it was just passing.
                    guard hovering else { return }
                    showing = true
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(conflicts) { conflict in
                        Text(conflict.summary)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(width: 300)
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
                        TokenPrompt.ask(service: service, displayName: name) {
                            hasToken = Keychain.hasToken(for: service)
                        }
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
