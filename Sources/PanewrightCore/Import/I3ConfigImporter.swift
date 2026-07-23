import Foundation

public struct I3ImportIssue: Equatable, Sendable {
    public var line: Int
    public var text: String
    public var reason: String

    public init(line: Int, text: String, reason: String) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}

public struct I3ImportResult: Sendable {
    public var config: PanewrightConfig
    public var issues: [I3ImportIssue]
}

/// Translates a real `~/.config/i3/config` into a PanewrightConfig.
/// Philosophy: translate what maps, and *loudly flag* everything that
/// doesn't — with line numbers — rather than silently dropping it.
public enum I3ConfigImporter {
    public static func importConfig(_ source: String) -> I3ImportResult {
        var issues: [I3ImportIssue] = []
        let rawLines = source.components(separatedBy: "\n")

        // Pass 1: variables ($mod and friends).
        var variables: [String: String] = [:]
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set ") else { continue }
            let parts = trimmed.dropFirst("set ".count)
                .split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].hasPrefix("$") {
                variables[String(parts[0])] = String(parts[1])
            }
        }
        let modToken = variables["$mod"]

        func substitute(_ line: String) -> String {
            var result = line
            for (name, value) in variables.sorted(by: { $0.key.count > $1.key.count }) {
                result = result.replacingOccurrences(of: name, with: value)
            }
            return result
        }

        var config = PanewrightConfig(
            bindings: [],
            modes: [],
            floatingApps: PanewrightConfig.default.floatingApps)
        // Mod1 is Alt — works natively. Mod4 (Super) maps to the hyper key.
        config.modifier = modToken == "Mod1" ? .alt : .hyper

        var importedModes: [(name: String, bindings: [PanewrightConfig.Binding])] = []
        var currentModeIndex: Int?
        var skippingBlockDepth = 0

        for (index, rawLine) in rawLines.enumerated() {
            let lineNumber = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if skippingBlockDepth > 0 {
                if trimmed.hasSuffix("{") { skippingBlockDepth += 1 }
                if trimmed == "}" { skippingBlockDepth -= 1 }
                continue
            }

            func flag(_ reason: String) {
                issues.append(I3ImportIssue(line: lineNumber, text: trimmed, reason: reason))
            }

            let line = substitute(trimmed)
            let words = line.split(separator: " ").map(String.init)
            guard let directive = words.first else { continue }

            switch directive {
            case "set":
                continue
            case "}":
                currentModeIndex = nil
            case "mode":
                guard line.hasSuffix("{") else {
                    flag("bare 'mode' directive outside a binding")
                    continue
                }
                let name = String(line.dropFirst("mode".count).dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                importedModes.append((name: name, bindings: []))
                currentModeIndex = importedModes.count - 1
            case "bindsym":
                handleBindsym(
                    words: words, modToken: modToken, inMode: currentModeIndex != nil,
                    flag: flag
                ) { binding in
                    if let currentModeIndex {
                        importedModes[currentModeIndex].bindings.append(binding)
                    } else {
                        config.bindings.append(binding)
                    }
                }
            case "bindcode":
                flag("keycode bindings (bindcode) aren't supported — use bindsym")
            case "gaps":
                if words.count >= 3, let value = Int(words[words.count - 1]) {
                    switch words[1] {
                    case "inner": config.gaps.inner = value
                    case "outer": config.gaps.outer = value
                    default: flag("unsupported gaps directive")
                    }
                } else {
                    flag("unsupported gaps directive")
                }
            case "bar":
                if line.hasSuffix("{") {
                    skippingBlockDepth = 1
                    flag("i3bar configuration — Panewright drives SketchyBar via the [bar] section instead")
                }
            case "client.focused":
                if words.count >= 2, isValidColor(words[1]) {
                    config.focusBorder.activeColor = words[1]
                } else {
                    flag("couldn't read client.focused border color")
                }
            case "client.unfocused":
                if words.count >= 2, isValidColor(words[1]) {
                    config.focusBorder.inactiveColor = words[1]
                }
            case let colorClass where colorClass.hasPrefix("client."):
                flag("color class '\(colorClass)' has no Panewright equivalent")
            case "for_window":
                if line.contains("floating enable") {
                    flag("floating rule: map the X11 class/instance to a macOS bundle ID in floating-apps")
                } else {
                    flag("for_window rules aren't supported")
                }
            case "assign":
                flag("assign rule: add the app's macOS bundle ID to [workspace-apps] instead of the X11 class")
            case "workspace":
                if words.count >= 4, words[2] == "output", let n = Int(words[1]) {
                    config.workspaceMonitors[n] = words[3]
                    flag("workspace→output imported as-is — adjust the monitor pattern ('main', 'secondary', or a name regex) for macOS")
                } else {
                    flag("unsupported workspace directive")
                }
            case "exec", "exec_always":
                flag("startup command not imported — use macOS login items")
            case "focus_follows_mouse":
                switch words.count > 1 ? words[1] : "" {
                case "yes": config.focusFollowsMouse = true
                case "no": config.focusFollowsMouse = false
                default: flag("unsupported focus_follows_mouse value")
                }
            default:
                flag("directive '\(directive)' has no Panewright equivalent")
            }
        }

        config.modes = importedModes.map {
            PanewrightConfig.Mode(name: $0.name, bindings: $0.bindings)
        }
        // Panewright's join mode is additive value — include it unless the
        // imported config defines its own.
        if !config.modes.contains(where: { $0.name == "join" }) {
            if let join = PanewrightConfig.default.modes.first(where: { $0.name == "join" }) {
                config.modes.append(join)
            }
        }
        return I3ImportResult(config: config, issues: issues)
    }

    // MARK: bindsym

    private static func handleBindsym(
        words: [String], modToken: String?, inMode: Bool,
        flag: (String) -> Void, append: (PanewrightConfig.Binding) -> Void
    ) {
        var parts = Array(words.dropFirst())
        while let first = parts.first, first.hasPrefix("--") {
            parts.removeFirst()
        }
        guard parts.count >= 2 else {
            flag("bindsym without a command")
            return
        }
        let combo = parts[0]
        let commandText = parts.dropFirst().joined(separator: " ")

        var hasMod = false
        var hasShift = false
        var extraModifiers: [String] = []
        var keyToken: String?
        for token in combo.split(separator: "+").map(String.init) {
            if let modToken, token == modToken {
                hasMod = true
            } else if token.lowercased() == "shift" {
                hasShift = true
            } else if ["Mod1", "Mod2", "Mod3", "Mod4", "Mod5", "Ctrl", "Control"].contains(token) {
                extraModifiers.append(token)
            } else {
                keyToken = token
            }
        }
        guard extraModifiers.isEmpty else {
            flag("modifier combination '\(combo)' isn't supported (only $mod and Shift)")
            return
        }
        guard inMode || hasMod else {
            flag("binding '\(combo)' doesn't use $mod — not imported")
            return
        }
        guard let keyToken, let key = mapKey(keyToken) else {
            flag("key '\(keyToken ?? combo)' has no macOS equivalent")
            return
        }

        var actions: [PanewrightConfig.Action] = []
        for part in commandText.split(separator: ";") {
            let command = part.trimmingCharacters(in: .whitespaces)
            let translation = translateCommand(command)
            if let action = translation.action {
                actions.append(action)
                if let note = translation.note {
                    flag(note)
                }
            } else {
                flag(translation.note ?? "unrecognized command '\(command)'")
            }
        }
        guard !actions.isEmpty else { return }
        append(
            PanewrightConfig.Binding(
                key: hasShift ? "shift-\(key)" : key, actions: actions))
    }

    static func mapKey(_ token: String) -> String? {
        let named: [String: String] = [
            "return": "enter", "escape": "esc", "space": "space",
            "left": "left", "right": "right", "up": "up", "down": "down",
            "minus": "minus", "equal": "equal", "tab": "tab",
            "comma": "comma", "period": "period", "slash": "slash",
            "semicolon": "semicolon", "apostrophe": "quote", "quote": "quote",
            "bracketleft": "leftSquareBracket", "bracketright": "rightSquareBracket",
        ]
        let lowered = token.lowercased()
        if let mapped = named[lowered] {
            return mapped
        }
        if lowered.count == 1, let scalar = lowered.unicodeScalars.first,
            CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
            return lowered
        }
        return nil
    }

    /// action == nil ⇒ untranslatable (note is the reason).
    /// action + note ⇒ imported with a warning worth surfacing.
    static func translateCommand(_ text: String) -> (action: PanewrightConfig.Action?, note: String?) {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else {
            return (nil, "empty command")
        }
        switch first {
        case "workspace":
            if let n = Int(words.last ?? "") {
                return (.workspace(n), nil)
            }
            return (nil, "only numbered workspaces are supported ('\(text)')")
        case "move":
            if text.hasPrefix("move container to workspace") || text.hasPrefix("move to workspace") {
                if let n = Int(words.last ?? "") {
                    return (.moveToWorkspace(n), nil)
                }
                return (nil, "only numbered workspaces are supported ('\(text)')")
            }
            if words.count == 2, let direction = PanewrightConfig.Direction(rawValue: words[1]) {
                return (.move(direction), nil)
            }
            if text == "move scratchpad" {
                return (.scratchpadMove, nil)
            }
            return (nil, "unsupported move command '\(text)'")
        case "focus":
            if words.count == 2, let direction = PanewrightConfig.Direction(rawValue: words[1]) {
                return (.focus(direction), nil)
            }
            return (nil, "'\(text)' (parent/child/output focus) isn't supported")
        case "fullscreen":
            return (.fullscreen, nil)
        case "floating":
            if words.count == 2, words[1] == "toggle" {
                return (.toggleFloating, nil)
            }
            return (nil, "unsupported floating command '\(text)'")
        case "kill":
            return (.close, nil)
        case "layout":
            switch words.count > 1 ? words[1] : "" {
            case "stacking", "tabbed":
                return (.layoutAccordion, "i3's \(words[1]) layout maps to AeroSpace's accordion")
            case "toggle", "splith", "splitv", "default":
                return (.layoutTiles, nil)
            default:
                return (nil, "unsupported layout command '\(text)'")
            }
        case "split", "splith", "splitv":
            return (nil, "pre-declared splits don't exist on AeroSpace — use Panewright's join mode ($mod+g) instead")
        case "mode":
            let name = words.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (.enterMode(name == "default" ? "main" : name), nil)
        case "resize":
            // resize (shrink|grow) (width|height) [N px [or M ppt]]
            guard words.count >= 3,
                let dimension = PanewrightConfig.ResizeDimension(rawValue: words[2])
            else {
                return (nil, "unsupported resize command '\(text)'")
            }
            let amount = words.count >= 4 ? Int(words[3]) ?? 10 : 10
            switch words[1] {
            case "shrink": return (.resize(dimension, -amount), nil)
            case "grow": return (.resize(dimension, amount), nil)
            default: return (nil, "unsupported resize command '\(text)'")
            }
        case "exec":
            var command = words.dropFirst().filter { $0 != "--no-startup-id" }
                .joined(separator: " ")
            let terminals = [
                "i3-sensible-terminal", "x-terminal-emulator", "xterm", "urxvt",
                "alacritty", "kitty", "gnome-terminal", "konsole", "st",
            ]
            if let program = command.split(separator: " ").first.map(String.init),
                terminals.contains(program) {
                command = "open -a Terminal"
                return (.exec(command), "Linux terminal launcher mapped to Terminal.app — point it at your terminal of choice")
            }
            return (.exec(command), "verify '\(command)' exists on macOS")
        case "scratchpad":
            return words.count == 2 && words[1] == "show"
                ? (.scratchpadShow, nil)
                : (nil, "unsupported scratchpad command '\(text)'")
        case "reload", "restart":
            return (nil, "'\(first)' isn't needed — Panewright applies config changes automatically")
        case "nop":
            return (nil, "nop binding skipped")
        default:
            return (nil, "unrecognized command '\(text)'")
        }
    }

    private static func isValidColor(_ value: String) -> Bool {
        (try? ColorHex.argb(fromCSSHex: value)) != nil
    }
}
