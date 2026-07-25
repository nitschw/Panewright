import Testing

@testable import PanewrightCore

/// The override tap swallows whatever these resolve to, so a wrong code means
/// silently eating the wrong key — the least debuggable bug a keyboard can have.
@Suite struct KeyCodesTests {
    @Test func theChordsMacOSReservesAllResolve() {
        // If any of these failed to parse, the override would quietly decline
        // to take the one chord the user asked it to take.
        for chord in BindingConflicts.systemChords.keys {
            #expect(KeyCodes.parse(chord: chord) != nil, "no key code for \(chord)")
        }
    }

    @Test func modifiersAreSeparatedFromTheKey() {
        let parsed = KeyCodes.parse(chord: "ctrl-cmd-f")
        #expect(parsed?.code == 3)  // where F sits on a US ANSI keyboard
        #expect(parsed?.modifiers == ["ctrl", "cmd"])
    }

    @Test func modifierOrderDoesNotMatter() {
        // Chords are built by different paths; a set comparison keeps them
        // from disagreeing over spelling.
        #expect(
            KeyCodes.parse(chord: "cmd-ctrl-f")?.modifiers
                == KeyCodes.parse(chord: "ctrl-cmd-f")?.modifiers)
    }

    @Test func aBareKeyHasNoModifiers() {
        let parsed = KeyCodes.parse(chord: "space")
        #expect(parsed?.code == 49)
        #expect(parsed?.modifiers.isEmpty == true)
    }

    @Test func anUnknownKeyIsRefusedRatherThanGuessed() {
        // Declining is right: an override that matched nothing, or matched
        // something else, is worse than not offering one.
        #expect(KeyCodes.parse(chord: "ctrl-cmd-f13") == nil)
        #expect(KeyCodes.parse(chord: "hyper-f") == nil)
    }

    @Test func everyKeyNameTheCheatSheetPrintsHasACode() {
        // The named keys a binding can actually use, so none of them silently
        // fall out of the override.
        let named = [
            "slash", "minus", "equal", "tab", "enter", "space", "esc",
            "left", "right", "up", "down", "backtick", "comma", "period",
            "semicolon", "quote",
        ]
        for name in named {
            #expect(KeyCodes.byName[name] != nil, "no key code for \(name)")
        }
    }

    @Test func digitsAndLettersAreDistinct() {
        // A duplicated code would make two different chords collide and one of
        // them swallow the other's key.
        let codes = Array(KeyCodes.byName.values)
        #expect(Set(codes).count == codes.count)
    }
}
