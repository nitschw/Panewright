import AppKit
import PanewrightCore
import SwiftUI

/// The conflicts window: every binding that can't do what it says, each with
/// the way out attached. A warning that only describes the problem makes the
/// user go find the fix themselves — so every row carries the buttons that
/// resolve it, and "Ignore" is a real answer that silences the bar chip too.
@MainActor @Observable
final class ConflictsModel {
    private let appModel: AppModel
    private(set) var config: PanewrightConfig
    /// True while a write is in flight, so the buttons can't be double-fired.
    private(set) var busy = false

    init(appModel: AppModel) {
        self.appModel = appModel
        self.config = (try? appModel.orchestrator.loadConfig()) ?? .default
    }

    var active: [BindingConflicts.Row] { BindingConflicts.rows(in: config) }

    var ignored: [BindingConflicts.Row] {
        let ignoredIDs = Set(config.ignoredConflicts)
        return BindingConflicts.rows(
            from: BindingConflicts.find(in: config).filter { ignoredIDs.contains($0.id) })
    }

    /// Re-read from disk — the editor may have fixed something since this
    /// window was last opened.
    func refresh() {
        config = (try? appModel.orchestrator.loadConfig()) ?? config
    }

    /// Ignoring a grouped row silences every stretch it stands for — a row
    /// that stays put after you dismiss it isn't a button, it's a taunt.
    func ignore(_ row: BindingConflicts.Row) {
        let new = row.conflictIDs.filter { !config.ignoredConflicts.contains($0) }
        guard !new.isEmpty else { return }
        write { $0.ignoredConflicts.append(contentsOf: new) }
    }

    func stopIgnoring(_ row: BindingConflicts.Row) {
        let ids = Set(row.conflictIDs)
        write { $0.ignoredConflicts.removeAll { ids.contains($0) } }
    }

    /// Ignores are stored in the config file, so they have to go through the
    /// same write-then-apply cycle as any other edit — that's what repaints
    /// the bar's ⚠ chip with the new count.
    private func write(_ mutate: (inout PanewrightConfig) -> Void) {
        busy = true
        defer { busy = false }
        var updated = (try? appModel.orchestrator.loadConfig()) ?? config
        mutate(&updated)
        do {
            try appModel.orchestrator.writeConfig(updated)
            try appModel.orchestrator.apply()
            config = updated
        } catch {
            appModel.report(error: "\(error)")
        }
    }

    func rebind(_ row: BindingConflicts.Row) {
        guard let key = row.rebindTarget else {
            // Mode bindings have no editor UI yet; the config file is the
            // honest answer rather than opening a window that can't help.
            NSWorkspace.shared.open(appModel.orchestrator.paths.panewrightConfigFile)
            return
        }
        appModel.openEditor(reveal: .binding(key: key))
    }

    func changeModKey() {
        appModel.openEditor(reveal: .modifier)
    }
}

struct ConflictsView: View {
    @Bindable var model: ConflictsModel
    @State private var showingIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.active.isEmpty && model.ignored.isEmpty {
                clean
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keybinding Conflicts").font(.title2).bold()
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    /// Counts rows, matching the bar chip exactly — a chip that says 2 and a
    /// window that says 21 would make both numbers untrustworthy.
    private var subtitle: String {
        switch model.active.count {
        case 0: "Nothing here needs your attention."
        case 1: "One thing to fix."
        case let count: "\(count) things to fix."
        }
    }

    private var clean: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Every binding is reachable and unambiguous.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.active) { conflict in
                    row(conflict, ignored: false)
                    Divider().padding(.leading, 22)
                }
                if !model.ignored.isEmpty {
                    DisclosureGroup(isExpanded: $showingIgnored) {
                        ForEach(model.ignored) { conflict in
                            row(conflict, ignored: true)
                        }
                    } label: {
                        Text("Ignored (\(model.ignored.count))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ row: BindingConflicts.Row, ignored: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(row))
                .foregroundStyle(ignored ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint(row)))
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                // A grouped row still has to say which keys it means; a bare
                // "20 bindings" is a number, not information.
                if case .ergonomics = row.content {
                    Text(chordList(row.chords))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Text(row.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if ignored {
                        Button("Stop Ignoring") { model.stopIgnoring(row) }
                    } else {
                        if case .single(let conflict) = row.content {
                            Button(conflict.scope == "main" ? "Rebind…" : "Open Config File…") {
                                model.rebind(row)
                            }
                        }
                        if row.implicatesModifier {
                            Button("Change Mod Key…") { model.changeModKey() }
                        }
                        Button("Ignore") { model.ignore(row) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.busy)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .opacity(ignored ? 0.6 : 1)
    }

    /// "⌃⌘⇧1, ⌃⌘⇧2, ⌃⌘⇧H +17 more" — enough to recognize the set without
    /// turning the row back into the twenty lines this grouping replaced.
    private func chordList(_ chords: [String]) -> String {
        let shown = chords.prefix(6)
        let rest = chords.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " +\(rest) more" : "")
    }

    private func icon(_ row: BindingConflicts.Row) -> String {
        switch row.content {
        case .single(let conflict):
            switch conflict.kind {
            case .duplicate: "doc.on.doc"
            case .systemShortcut: "apple.logo"
            case .awkward: "hand.raised"
            }
        case .ergonomics: "hand.raised"
        }
    }

    /// Orange for "this doesn't work", yellow for "this works but hurts".
    private func tint(_ row: BindingConflicts.Row) -> Color {
        switch row.content {
        case .single(let conflict):
            if case .awkward = conflict.kind { .yellow } else { .orange }
        case .ergonomics: .yellow
        }
    }

    private var footer: some View {
        HStack {
            Text("Checked whenever the config changes.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Recheck") { model.refresh() }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

@MainActor
final class ConflictsWindowController {
    private var window: NSWindow?
    private var model: ConflictsModel?

    func show(appModel: AppModel) {
        let model = self.model ?? ConflictsModel(appModel: appModel)
        self.model = model
        // The config may have changed since this window was last closed —
        // a conflicts list that's out of date is worse than none.
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: ConflictsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Keybinding Conflicts"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
