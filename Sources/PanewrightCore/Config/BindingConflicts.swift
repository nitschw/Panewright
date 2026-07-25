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
            /// Playable, but an uncomfortable stretch on a Mac keyboard.
            case awkward(modifiers: Int, suggestion: String)

            /// Names the class of problem. One key can hit more than one
            /// (bound twice AND an awkward stretch), so the tag is what keeps
            /// those apart as separate, separately-dismissable rows.
            public var tag: String {
                switch self {
                case .duplicate: "duplicate"
                case .systemShortcut: "system"
                case .awkward: "awkward"
                }
            }
        }

        public var id: String { "\(scope)/\(key)/\(kind.tag)" }
        /// "main" for top-level bindings, else the mode name.
        public let scope: String
        public let key: String
        /// The chord as actually pressed — "ctrl-cmd-shift-h" for a top-level
        /// binding, the bare key inside a mode. What the user has to recognize.
        public let chord: String
        public let kind: Kind

        public init(scope: String, key: String, chord: String, kind: Kind) {
            self.scope = scope
            self.key = key
            self.chord = chord
            self.kind = kind
        }

        public var summary: String {
            switch kind {
            case .duplicate(let actions):
                "\(display) is bound twice (\(actions.joined(separator: " / "))) — only the last one runs"
            case .systemShortcut(let owner):
                "\(display) is taken by macOS (\(owner)) and may never reach Panewright"
            case .awkward(let modifiers, let suggestion):
                "\(display) needs \(modifiers) modifiers at once — \(suggestion)"
            }
        }

        /// What's wrong, without restating the chord — for surfaces that
        /// already show the chord separately.
        public var explanation: String {
            let prefix = display + " "
            return summary.hasPrefix(prefix)
                ? String(summary.dropFirst(prefix.count)) : summary
        }

        /// The chord as it reads on the keycaps, scoped when it lives in a mode.
        public var display: String {
            let pretty = KeyChordFormatter.pretty(chord)
            return scope == "main" ? pretty : "\(scope) mode: \(pretty)"
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

    /// One line in the conflicts window — and one unit of the bar chip's count.
    ///
    /// A row is a *fix*, not a finding. The ergonomics warnings are the reason
    /// this distinction exists: a default keymap turns up twenty three-modifier
    /// stretches, but they share a single remedy, so twenty rows would be
    /// nineteen copies of one sentence and a chip reading ⚠ 21 on a fresh
    /// install — the "cry wolf" failure that trains people to ignore warnings.
    public struct Row: Equatable, Sendable, Identifiable {
        public enum Content: Equatable, Sendable {
            case single(Conflict)
            /// Every three-modifier stretch, collapsed.
            case ergonomics(chords: [String], modifiers: Int, suggestion: String)
        }

        public let id: String
        public let content: Content
        /// Every conflict this row stands for — what "Ignore" has to silence
        /// for the row to actually disappear.
        public let conflictIDs: [String]

        /// The headline: a chord, or how many chords are in the same boat.
        public var title: String {
            switch content {
            case .single(let conflict): conflict.display
            case .ergonomics(let chords, _, _): "\(chords.count) bindings"
            }
        }

        public var detail: String {
            switch content {
            case .single(let conflict): conflict.explanation
            case .ergonomics(_, let modifiers, let suggestion):
                "need \(modifiers) modifiers at once — \(suggestion)"
            }
        }

        /// The chords this row covers, so a grouped row can still show which
        /// keys it means rather than just a count.
        public var chords: [String] {
            switch content {
            case .single(let conflict): [conflict.display]
            case .ergonomics(let chords, _, _): chords
            }
        }

        /// Changing the mod key fixes the two problems the modifier itself
        /// causes; it does nothing about a key that's bound twice.
        public var implicatesModifier: Bool {
            switch content {
            case .single(let conflict):
                if case .duplicate = conflict.kind { false } else { true }
            case .ergonomics: true
            }
        }

        /// Only a single top-level binding can be pointed at in the editor;
        /// a group has no one row to jump to, and modes have no editor UI.
        public var rebindTarget: String? {
            guard case .single(let conflict) = content, conflict.scope == "main" else {
                return nil
            }
            return conflict.key
        }
    }

    /// Conflicts as they're presented, grouped so each row is one decision.
    public static func rows(in config: PanewrightConfig) -> [Row] {
        rows(from: active(in: config))
    }

    /// Grouped rows for an arbitrary list — used for the active list and the
    /// ignored one alike, so ignoring a group doesn't fragment it on the way back.
    public static func rows(from conflicts: [Conflict]) -> [Row] {
        var rows: [Row] = []
        var stretches: [Conflict] = []
        for conflict in conflicts {
            if case .awkward = conflict.kind {
                stretches.append(conflict)
            } else {
                rows.append(
                    Row(id: conflict.id, content: .single(conflict), conflictIDs: [conflict.id]))
            }
        }
        // One stretch is not a pattern — grouping a single item just hides it
        // behind a count.
        if stretches.count == 1 {
            let only = stretches[0]
            rows.append(Row(id: only.id, content: .single(only), conflictIDs: [only.id]))
        } else if stretches.count > 1 {
            // All twenty carry the same modifier count and the same advice.
            guard case .awkward(let modifiers, let suggestion) = stretches[0].kind else {
                return rows
            }
            rows.append(
                Row(
                    id: "ergonomics",
                    content: .ergonomics(
                        chords: stretches.map(\.display), modifiers: modifiers,
                        // The advice was written for one chord; this row is
                        // about twenty of them.
                        suggestion: suggestion.replacingOccurrences(
                            of: "reach it", with: "reach them")),
                    conflictIDs: stretches.map(\.id)))
        }
        return rows
    }

    /// The conflicts still worth interrupting someone about: everything
    /// `find` turns up, minus the ones they've explicitly chosen to keep.
    /// This is what the bar chip counts and the conflicts window leads with.
    public static func active(in config: PanewrightConfig) -> [Conflict] {
        let ignored = Set(config.ignoredConflicts)
        return find(in: config).filter { !ignored.contains($0.id) }
    }

    /// Every conflict in a config, in a stable order.
    public static func find(in config: PanewrightConfig) -> [Conflict] {
        var conflicts: [Conflict] = []
        conflicts += duplicates(in: config.bindings, scope: "main") {
            AeroSpaceConfigEmitter.keyCombo(modifier: config.modifier, key: $0)
        }
        for mode in config.modes {
            // Mode keys are pressed bare, so the key is the chord.
            conflicts += duplicates(in: mode.bindings, scope: mode.name) { $0 }
        }
        // Only top-level bindings carry the modifier; mode keys are bare, so
        // they can't collide with a system chord.
        for binding in config.bindings {
            let chord = AeroSpaceConfigEmitter.keyCombo(
                modifier: config.modifier, key: binding.key)
            if let owner = systemChords[chord.lowercased()] {
                conflicts.append(
                    Conflict(
                        scope: "main", key: binding.key, chord: chord,
                        kind: .systemShortcut(owner: owner)))
            }
        }
        if config.modifier == .leader, let owner = systemChords[config.leaderKey.lowercased()] {
            conflicts.append(
                Conflict(
                    scope: "main", key: config.leaderKey, chord: config.leaderKey,
                    kind: .systemShortcut(owner: owner)))
        }
        conflicts += awkwardChords(in: config)
        return conflicts
    }

    /// Mac keyboards put Control and Shift on the same pinky, so a binding
    /// needing three or more held modifiers is a genuine stretch. Modes and a
    /// one-key modifier both dissolve these, so the warning names the fix
    /// rather than just complaining.
    static func awkwardChords(in config: PanewrightConfig) -> [Conflict] {
        // Hyper is one physical key (Caps Lock), so it never counts as a stretch.
        guard config.modifier != .hyper, config.modifier != .leader else { return [] }
        let base = config.modifier.rawValue.split(separator: "-").count
        guard base >= 2 else { return [] }  // single-modifier setups are fine
        // One row per chord, not per binding: a key bound twice is already
        // reported as a duplicate, and listing its stretch twice would just
        // make the same fix look like two.
        var seen: Set<String> = []
        return config.bindings.compactMap { binding in
            guard binding.key.hasPrefix("shift-") else { return nil }
            guard seen.insert(binding.key.lowercased()).inserted else { return nil }
            return Conflict(
                scope: "main", key: binding.key,
                chord: AeroSpaceConfigEmitter.keyCombo(
                    modifier: config.modifier, key: binding.key),
                kind: .awkward(
                    modifiers: base + 1,
                    suggestion:
                        "use a mode, or Caps Lock as hyper, to reach it with two fingers"))
        }
    }

    private static func duplicates(
        in bindings: [PanewrightConfig.Binding], scope: String,
        chord: (String) -> String
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
            return Conflict(
                scope: scope, key: key, chord: chord(key),
                kind: .duplicate(actions: described))
        }
    }
}
