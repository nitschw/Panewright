import Foundation

/// Finds keybindings that can't do what they say — two bindings claiming the
/// same key, or a binding macOS will swallow before AeroSpace ever sees it.
///
/// A binding that silently does nothing is the worst kind of bug: nothing is
/// broken, nothing is logged, the key just doesn't work. Surfacing these keeps
/// the importer's promise — flag what we can't honor, never fail silently.
public enum BindingConflicts {
    public struct Conflict: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// Two bindings in the same scope claim one key.
            case duplicate(actions: [String])
            /// macOS claims the chord system-wide, so it never reaches us.
            case systemShortcut(owner: String)
        }

        public var id: String { "\(scope)/\(key)" }
        /// "main" for top-level bindings, else the mode name.
        public let scope: String
        public let key: String
        public let kind: Kind

        public var summary: String {
            switch kind {
            case .duplicate(let actions):
                "\(display) is bound twice (\(actions.joined(separator: " / "))) — only the last one runs"
            case .systemShortcut(let owner):
                "\(display) is taken by macOS (\(owner)) and may never reach Panewright"
            }
        }

        private var display: String {
            scope == "main" ? "$mod+\(key)" : "\(scope) mode: \(key)"
        }
    }

    /// Chords macOS reserves. Only the ones that genuinely swallow the event
    /// are listed — crying wolf about every system shortcut would train people
    /// to ignore the warnings.
    static let systemChords: [String: String] = [
        "ctrl-cmd-space": "Emoji & Symbols picker",
        "cmd-space": "Spotlight",
        "cmd-tab": "App switcher",
        "ctrl-cmd-f": "Enter Full Screen",
        "ctrl-cmd-q": "Lock Screen",
        "cmd-q": "Quit application",
        "cmd-w": "Close window",
        "cmd-h": "Hide application",
        "cmd-m": "Minimize",
        "ctrl-up": "Mission Control",
        "ctrl-down": "Application windows",
        "ctrl-left": "Move left a space",
        "ctrl-right": "Move right a space",
    ]

    /// Every conflict in a config, in a stable order.
    public static func find(in config: PanewrightConfig) -> [Conflict] {
        var conflicts: [Conflict] = []
        conflicts += duplicates(in: config.bindings, scope: "main")
        for mode in config.modes {
            conflicts += duplicates(in: mode.bindings, scope: mode.name)
        }
        // Only top-level bindings carry the modifier; mode keys are bare, so
        // they can't collide with a system chord.
        for binding in config.bindings {
            let chord = AeroSpaceConfigEmitter.keyCombo(
                modifier: config.modifier, key: binding.key)
            if let owner = systemChords[chord.lowercased()] {
                conflicts.append(
                    Conflict(scope: "main", key: binding.key, kind: .systemShortcut(owner: owner)))
            }
        }
        if config.modifier == .leader, let owner = systemChords[config.leaderKey.lowercased()] {
            conflicts.append(
                Conflict(
                    scope: "main", key: config.leaderKey, kind: .systemShortcut(owner: owner)))
        }
        return conflicts
    }

    private static func duplicates(
        in bindings: [PanewrightConfig.Binding], scope: String
    ) -> [Conflict] {
        var seen: [String: [[PanewrightConfig.Action]]] = [:]
        var order: [String] = []
        for binding in bindings {
            let key = binding.key.lowercased()
            if seen[key] == nil { order.append(key) }
            seen[key, default: []].append(binding.actions)
        }
        return order.compactMap { key in
            guard let entries = seen[key], entries.count > 1 else { return nil }
            let described = entries.map { actions in
                actions.map(PanewrightConfigSerializer.actionString).joined(separator: "; ")
            }
            return Conflict(scope: scope, key: key, kind: .duplicate(actions: described))
        }
    }
}
