import Foundation

/// Maps Panewright's key names to macOS virtual key codes.
///
/// Needed only by the shortcut-override tap, which sees key *codes* — an event
/// arrives as "key 3 with Command and Control held", never as "ctrl-cmd-f".
///
/// These are positional codes, not characters. Code 3 is the key where F sits
/// on a US ANSI keyboard, whatever that key produces under the user's layout,
/// which is the same convention AeroSpace's own key names follow. So a binding
/// keeps working on a Dvorak or AZERTY layout in the same way it does in
/// AeroSpace, rather than following the printed character around.
public enum KeyCodes {
    /// Name → virtual key code, for every key name a binding can use.
    public static let byName: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
        "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "equal": 24, "minus": 27,
        "rightbracket": 30, "leftbracket": 33,
        "quote": 39, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44,
        "period": 47, "backtick": 50,
        "enter": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// The modifiers and base key of a chord like "ctrl-cmd-shift-f".
    ///
    /// Returns nil for a key we have no code for, since an override that
    /// silently matched nothing would be worse than declining to offer one.
    public static func parse(chord: String) -> (code: UInt16, modifiers: Set<String>)? {
        var parts = chord.lowercased().split(separator: "-").map(String.init)
        guard let base = parts.popLast(), let code = byName[base] else { return nil }
        let known: Set<String> = ["cmd", "alt", "ctrl", "shift"]
        guard parts.allSatisfy(known.contains) else { return nil }
        return (code, Set(parts))
    }
}
