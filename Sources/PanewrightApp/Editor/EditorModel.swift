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
    var statusLine = ""
    private var pendingSave: Task<Void, Never>?

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
    }

    /// Called by every control mutation: debounce, then save + apply.
    func configChanged() {
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

    func reloadFromDisk() {
        let loaded = (try? appModel.orchestrator.loadConfig()) ?? config
        config = loaded
        bindingRows = loaded.bindings.map {
            BindingRow(key: $0.key, action: PanewrightConfigSerializer.chainString($0.actions))
        }
        bindingErrors = [:]
        statusLine = "Reloaded from file"
    }

    func saveAsProfile() {
        appModel.saveCurrentAsProfile()
    }
}
