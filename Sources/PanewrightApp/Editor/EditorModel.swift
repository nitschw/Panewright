import Foundation
import PanewrightCore
import SwiftUI

/// The visual editor's state: a config model whose every mutation debounces
/// into a serialize → write → live-apply cycle. The file, the GUI, and the
/// running layout can never disagree.
@MainActor @Observable
final class EditorModel {
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
    }

    /// The resolved destination, in terms this editor's views can anchor to.
    enum Reveal: Equatable, Hashable {
        case modifier
        case binding(UUID)
    }

    struct BindingRow: Identifiable {
        let id = UUID()
        var key: String
        var action: String
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        let loaded = (try? appModel.orchestrator.loadConfig()) ?? .default
        self.config = loaded
        self.bindingRows = loaded.bindings.map {
            BindingRow(key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
        }
        recomputeConflicts()
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
        bindingRows = loaded.bindings.map {
            BindingRow(key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
        }
        bindingErrors = [:]
        recomputeConflicts()
        if !quiet { statusLine = "Reloaded from file" }
    }

    /// Point the editor at something. Call after any reload — row ids are
    /// regenerated on load, so a target resolved earlier would be stale.
    func reveal(_ target: Target) {
        switch target {
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
