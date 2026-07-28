import Foundation
import PanewrightCore
import SwiftUI

/// The visual editor's state: a config model whose every mutation debounces
/// into a serialize → write → live-apply cycle. The file, the GUI, and the
/// running layout can never disagree.
@MainActor @Observable
final class SettingsModel {
    private let appModel: AppModel
    var config: PanewrightConfig
    var bindingRows: [BindingRow]
    var bindingErrors: [UUID: String] = [:]
    /// Conflicts affecting each top-level binding key (lowercased), so a row
    /// can mark itself without rescanning the whole config per redraw.
    ///
    /// Only breakage — a key bound twice, or one macOS swallows. The
    /// three-modifier stretches are deliberately left out: under a chorded
    /// mod key twenty rows would go red at once, which is a wall of alarm
    /// about a preference, not a fault. They stay in the conflicts window.
    var conflictsByKey: [String: [BindingConflicts.Conflict]] = [:]
    var statusLine = ""
    /// What the editor should scroll to and mark when it opens — set when
    /// something else (the conflicts window) sends the user here to fix a
    /// specific thing. Dropping someone at the top of a long scroll view and
    /// letting them hunt is how a "fix it" button stops being one.
    var revealed: Reveal?
    private var pendingSave: Task<Void, Never>?
    private var clearReveal: Task<Void, Never>?

    /// Where a caller can send the editor. Carries the binding's key rather
    /// than a row id, since rows are rebuilt (with new ids) on every load.
    enum Target: Equatable {
        case modifier
        case binding(key: String)
        /// The widget toggles, which live on the Appearance tab with the
        /// rest of the bar — one tab for everything the bar looks like.
        case widgets
        case layout
        case appearance
        /// The Keybindings tab itself, with no particular binding to find.
        /// Distinct from `.binding`, which hunts for a key and complains when
        /// there isn't one — a deep link to the tab shouldn't report a
        /// failure to locate a binding nobody asked for.
        case keybindings
        /// The Scripting tab: hooks and menu scripts.
        case scripting

        /// Resolve a deep-link path segment. An unknown or missing segment
        /// opens Settings without jumping anywhere, which is friendlier than
        /// refusing to open at all.
        init?(tab: String?) {
            switch tab {
            case "keys", "keybindings": self = .keybindings
            case "scripting", "scripts", "hooks": self = .scripting
            case "layout": self = .layout
            case "appearance": self = .appearance
            case "bar", "widgets", "status-bar": self = .widgets
            case "general": self = .modifier
            default: return nil
            }
        }
    }

    /// The resolved destination, in terms this editor's views can anchor to.
    enum Reveal: Equatable, Hashable {
        case modifier
        case binding(UUID)
        case widgets
        case layout
        case appearance
        /// The Keybindings tab itself, with no particular binding to find.
        /// Distinct from `.binding`, which hunts for a key and complains when
        /// there isn't one — a deep link to the tab shouldn't report a
        /// failure to locate a binding nobody asked for.
        case keybindings
        /// The Scripting tab: hooks and menu scripts.
        case scripting
    }

    struct BindingRow: Identifiable {
        let id = UUID()
        var key: String
        var action: String
    }

    /// A mode and its bindings. Modes were previously editable only by hand in
    /// the config file, which made the one feature that most needs a GUI — a
    /// mode full of bare single keys — the one you had to write TOML for.
    struct ModeRow: Identifiable {
        let id = UUID()
        var name: String
        var bindings: [BindingRow]
    }

    /// A two-column mapping (workspace → monitor, app → workspace). Both are
    /// dictionaries in the config, and a dictionary can't be edited in place
    /// without a stable row identity to type into.
    struct MappingRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var modeRows: [ModeRow] = []
    var workspaceMonitorRows: [MappingRow] = []
    var appWorkspaceRows: [MappingRow] = []
    var barMonitorRows: [BarMonitorRow] = []

    /// One [[bar.monitor]] rule. `widgets` is the user's comma list, kept as
    /// text so half-typed keys don't get eaten by a round-trip.
    struct BarMonitorRow: Identifiable {
        let id = UUID()
        var match: String
        var mode: WidgetMode
        var widgets: String
        var hidden: Bool

        enum WidgetMode: String, CaseIterable {
            case all = "All widgets"
            case none = "Strip only"
            case custom = "These:"
        }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        let loaded = (try? appModel.orchestrator.loadConfig()) ?? .default
        self.config = loaded
        self.bindingRows = loaded.bindings.map {
            BindingRow(key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
        }
        loadRows(from: loaded)
        recomputeConflicts()
    }

    private static func sorted(_ rows: [BindingRow]) -> [BindingRow] {
        rows.sorted { BindingOrder.before($0.key, $1.key) }
    }

    /// Re-sort in place — used after an edit changes a key, so a renamed
    /// binding moves to where it now belongs.
    func sortBindingRows() {
        bindingRows = Self.sorted(bindingRows)
    }

    /// Rebuild every row-backed editor from a config. Row ids are regenerated
    /// here, which is why `reveal` must always run after a load.
    private func loadRows(from config: PanewrightConfig) {
        bindingRows = Self.sorted(
            config.bindings.map {
                BindingRow(key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
            })
        modeRows = config.modes.map { mode in
            ModeRow(
                name: mode.name,
                bindings: mode.bindings.map {
                    BindingRow(
                        key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
                })
        }
        // Sorted so the list doesn't reshuffle between openings — dictionary
        // order is arbitrary and a jumping list is unusable.
        workspaceMonitorRows = config.workspaceMonitors.sorted { $0.key < $1.key }
            .map { MappingRow(key: "\($0.key)", value: $0.value) }
        appWorkspaceRows = config.appWorkspaces.sorted { $0.key < $1.key }
            .map { MappingRow(key: $0.key, value: "\($0.value)") }
        barMonitorRows = config.statusBar.monitorProfiles.map { profile in
            BarMonitorRow(
                match: profile.match,
                mode: profile.hidden
                    ? .all
                    : profile.widgets == nil ? .all : profile.widgets!.isEmpty ? .none : .custom,
                widgets: (profile.widgets ?? []).joined(separator: ", "),
                hidden: profile.hidden)
        }
    }

    /// Recomputed on every config change so a row goes red the moment its key
    /// becomes a duplicate — the warning is worth much less after the save.
    private func recomputeConflicts() {
        var byKey: [String: [BindingConflicts.Conflict]] = [:]
        for conflict in BindingConflicts.active(in: config) where conflict.scope == "main" {
            if case .awkward = conflict.kind { continue }
            byKey[conflict.key.lowercased(), default: []].append(conflict)
        }
        conflictsByKey = byKey
    }

    func conflicts(for key: String) -> [BindingConflicts.Conflict] {
        conflictsByKey[key.trimmingCharacters(in: .whitespaces).lowercased()] ?? []
    }

    /// Called by every control mutation: debounce, then save + apply.
    func configChanged() {
        // The mod key is a control like any other here, and changing it makes
        // and unmakes system collisions — ⌃⌘F clashes, ⌥F doesn't.
        recomputeConflicts()
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func bindingRowsChanged() {
        guard syncBindingRows() else {
            statusLine = "Fix the highlighted bindings to apply"
            return
        }
        configChanged()
    }

    /// Modes are all-or-nothing like bindings: a mode whose keys don't parse
    /// is never written, so a typo can't silently drop the rest of it.
    func modeRowsChanged() {
        var modes: [PanewrightConfig.Mode] = []
        var errors: [UUID: String] = [:]
        for mode in modeRows {
            let name = mode.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var bindings: [PanewrightConfig.Binding] = []
            for row in mode.bindings {
                let key = row.key.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                do {
                    bindings.append(
                        PanewrightConfig.Binding(
                            key: key, actions: try ConfigParser.parseActionChain(row.action)))
                } catch {
                    errors[row.id] = "\(error)"
                }
            }
            modes.append(PanewrightConfig.Mode(name: name, bindings: bindings))
        }
        bindingErrors = bindingErrors.filter { modeRowIDs.contains($0.key) == false }
            .merging(errors) { _, new in new }
        guard errors.isEmpty else {
            statusLine = "Fix the highlighted mode bindings to apply"
            return
        }
        config.modes = modes
        configChanged()
    }

    private var modeRowIDs: Set<UUID> {
        Set(modeRows.flatMap { $0.bindings.map(\.id) })
    }

    /// Workspace → monitor. Non-numeric workspaces are skipped rather than
    /// rejected: the row is probably half-typed.
    func workspaceMonitorRowsChanged() {
        var monitors: [Int: String] = [:]
        for row in workspaceMonitorRows {
            guard let workspace = Int(row.key.trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            let monitor = row.value.trimmingCharacters(in: .whitespaces)
            guard !monitor.isEmpty else { continue }
            monitors[workspace] = monitor
        }
        config.workspaceMonitors = monitors
        configChanged()
    }

    /// [[bar.monitor]] rules. A rule with an empty match is half-typed and
    /// skipped, never dropped from the editor.
    func barMonitorRowsChanged() {
        config.statusBar.monitorProfiles = barMonitorRows.compactMap { row in
            let match = row.match.trimmingCharacters(in: .whitespaces)
            guard !match.isEmpty else { return nil }
            let widgets: [String]? =
                switch row.mode {
                case .all: nil
                case .none: []
                case .custom:
                    row.widgets.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            return .init(match: match, widgets: widgets, hidden: row.hidden)
        }
        configChanged()
    }

    /// App bundle ID → workspace number.
    func appWorkspaceRowsChanged() {
        var assignments: [String: Int] = [:]
        for row in appWorkspaceRows {
            let bundleID = row.key.trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty,
                let workspace = Int(row.value.trimmingCharacters(in: .whitespaces))
            else { continue }
            assignments[bundleID] = workspace
        }
        config.appWorkspaces = assignments
        configChanged()
    }

    /// Returns false (and populates errors) if any row fails to parse; the
    /// config is only updated when every row is valid — never drop bindings.
    private func syncBindingRows() -> Bool {
        var bindings: [PanewrightConfig.Binding] = []
        var errors: [UUID: String] = [:]
        for row in bindingRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                errors[row.id] = "key is empty"
                continue
            }
            do {
                bindings.append(
                    PanewrightConfig.Binding(
                        key: key,
                        actions: try ConfigParser.parseActionChain(row.action)))
            } catch {
                errors[row.id] = "\(error)"
            }
        }
        bindingErrors = errors
        guard errors.isEmpty else { return false }
        config.bindings = bindings
        recomputeConflicts()
        return true
    }

    private func save() {
        // The write is fast and stays here; the apply shells out repeatedly
        // and must never run on the main actor — editing a slider used to
        // pinwheel the Settings window while the engine reloaded.
        do {
            try appModel.orchestrator.writeConfig(config)
        } catch {
            statusLine = "\(error)"
            appModel.report(error: "\(error)")
            return
        }
        let orchestrator = appModel.orchestrator
        let insets = (DockInset.bottom, DockInset.sides)
        // MainActor closure built here so neither `self` nor `appModel`
        // crosses the detachment boundary — CI's stricter checker insists.
        let finish: @MainActor @Sendable (String?) -> Void = { [weak self, weak appModel] failure in
            self?.statusLine = failure ?? "Applied"
            if let failure { appModel?.report(error: failure) }
            appModel?.refreshStatus()
        }
        Task.detached(priority: .userInitiated) {
            let failure: String? = {
                do {
                    try orchestrator.apply(dockInsetBottom: insets.0, dockInsetSides: insets.1)
                    return nil
                } catch {
                    return "\(error)"
                }
            }()
            await finish(failure)
        }
    }

    /// `quiet` is for reloads the user didn't ask for — reopening the window
    /// picks up edits made elsewhere, and announcing that would be noise.
    func reloadFromDisk(quiet: Bool = false) {
        let loaded = (try? appModel.orchestrator.loadConfig()) ?? config
        config = loaded
        loadRows(from: loaded)
        bindingErrors = [:]
        recomputeConflicts()
        if !quiet { statusLine = "Reloaded from file" }
    }

    /// Point the editor at something. Call after any reload — row ids are
    /// regenerated on load, so a target resolved earlier would be stale.
    func reveal(_ target: Target) {
        switch target {
        case .widgets:
            revealed = .widgets
        case .layout:
            revealed = .layout
        case .appearance:
            revealed = .appearance
        case .keybindings:
            revealed = .keybindings
        case .scripting:
            revealed = .scripting
        case .modifier:
            revealed = .modifier
        case .binding(let key):
            guard
                let row = bindingRows.first(where: {
                    $0.key.caseInsensitiveCompare(key) == .orderedSame
                })
            else {
                statusLine = "No binding for \(key) — it may live in a mode"
                revealed = nil
                return
            }
            revealed = .binding(row.id)
        }
        // Let the mark fade: it's a "here" pointer, not a permanent state, and
        // a row that stays highlighted looks like an error.
        clearReveal?.cancel()
        clearReveal = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            revealed = nil
        }
    }

    func saveAsProfile() {
        appModel.saveCurrentAsProfile()
    }
}
