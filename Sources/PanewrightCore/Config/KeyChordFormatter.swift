import Foundation

/// Turns AeroSpace's wire syntax into what's printed on the keys — "ctrl-cmd-shift-h"
/// reads as ⌃⌘⇧H. Every surface that shows a binding (cheat sheet, conflict list,
/// the bar) formats it the same way, so a chord is recognizable wherever it appears.
public enum KeyChordFormatter {
    /// "shift-h" → "⇧H", "shift-slash" → "?", "minus" → "−", "tab" → "⇥".
    public static func prettyKey(_ key: String) -> String {
        let shifted = key.hasPrefix("shift-")
        let base = shifted ? String(key.dropFirst(6)) : key
        let named: [String: String] = [
            "slash": shifted ? "?" : "/", "minus": "−", "equal": "=",
            "tab": "⇥", "enter": "⏎", "space": "Space", "esc": "Esc",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
            "backtick": "`", "comma": ",", "period": ".", "semicolon": ";",
            "quote": "'",
        ]
        if base == "slash", shifted { return "?" }
        let display = named[base] ?? base.uppercased()
        return (shifted && named[base] == nil ? "⇧" : "") + display
    }

    /// "ctrl-cmd" → "⌃⌘", "cmd-backtick" → "⌘`".
    public static func pretty(_ chord: String) -> String {
        chord.split(separator: "-").map { part in
            switch part {
            case "ctrl": "⌃"
            case "cmd": "⌘"
            case "alt": "⌥"
            case "shift": "⇧"
            default: prettyKey(String(part))
            }
        }.joined()
    }
}
