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
        /// The Status Bar tab, which absorbed the old standalone Widgets
        /// window rather than duplicating every toggle in two places.
        case widgets
        case layout
        case appearance
        /// The Keybindings tab itself, with no particular binding to find.
        /// Distinct from `.binding`, which hunts for a key and complains when
        /// there isn't one — a deep link to the tab shouldn't report a
        /// failure to locate a binding nobody asked for.
        case keybindings

        /// Resolve a deep-link path segment. An unknown or missing segment
        /// opens Settings without jumping anywhere, which is friendlier than
        /// refusing to open at all.
        init?(tab: String?) {
            switch tab {
            case "keys", "keybindings": self = .keybindings
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

    /// Bindings in the order they're easiest to find in.
    ///
    /// Config order is authoring order — whatever the importer or the defaults
    /// happened to emit — which makes scanning fifty rows for one key a hunt.
    /// Sorted, a key is where you'd look for it.
    ///
    /// Digits before letters, and numbers compared as numbers so 10 follows 9
    /// rather than sitting between 1 and 2. A modifier prefix sorts with the
    /// key it modifies (shift-h next to h) rather than collecting every
    /// shift- binding into one block, since what you're looking for is the
    /// key, not the modifier.
    static func sortKey(_ key: String) -> (Int, String, Int, String) {
        let lowered = key.lowercased()
        let separator = lowered.lastIndex(of: "-")
        let modifier = separator.map { String(lowered[lowered.startIndex..<$0]) } ?? ""
        let base = separator.map { String(lowered[lowered.index(after: $0)...]) } ?? lowered
        let digits = Int(base)
        // Digits first, then by numeric value or by name, then the bare key
        // ahead of its modified variants.
        return (digits == nil ? 1 : 0, digits == nil ? base : "", digits ?? 0, modifier)
    }

    private static func sorted(_ rows: [BindingRow]) -> [BindingRow] {
        rows.sorted { sortKey($0.key) < sortKey($1.key) }
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
        do {
            try appModel.orchestrator.writeConfig(config)
            try appModel.orchestrator.apply()
            statusLine = "Applied"
        } catch {
            statusLine = "\(error)"
            appModel.report(error: "\(error)")
        }
        appModel.refreshStatus()
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
