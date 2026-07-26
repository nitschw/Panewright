import Testing

@testable import PanewrightCore

/// This ordering shipped untested, because it lived in the app target where
/// there is no test target at all. Moving it into Core was most of the point.
@Suite struct BindingOrderTests {
    private func order(_ keys: [String]) -> [String] {
        keys.sorted(by: BindingOrder.before)
    }

    @Test func digitsSortNumericallyNotAsText() {
        // As text, "10" sorts between "1" and "2" — a list where workspace 10
        // interrupts the count reads as broken.
        #expect(order(["10", "2", "1", "0"]) == ["0", "1", "2", "10"])
    }

    @Test func aModifiedKeySitsBesideTheKeyItModifies() {
        // The reported problem. Sorting raw strings files every shift- binding
        // together under S, so shift-1 ends up nine rows away from 1 — but
        // what you're scanning for is the key, and the modifier is a variant.
        #expect(
            order(["shift-2", "1", "shift-1", "2", "0", "shift-0"])
                == ["0", "shift-0", "1", "shift-1", "2", "shift-2"])
    }

    @Test func zeroLeadsRatherThanTrailingTheNumberRow() {
        // Config order follows the keyboard (1…9 then 0). The list is read as
        // numbers, so 0 goes first.
        let keys = (1...9).map(String.init) + ["0"]
        #expect(order(keys).first == "0")
        #expect(order(keys).last == "9")
    }

    @Test func digitsComeBeforeLetters() {
        #expect(order(["h", "1", "tab", "0"]) == ["0", "1", "h", "tab"])
    }

    @Test func namedKeysSortAlphabetically() {
        #expect(order(["tab", "enter", "space", "esc"]) == ["enter", "esc", "space", "tab"])
    }

    @Test func theBareKeyComesBeforeItsModifiedForms() {
        #expect(order(["shift-h", "h"]) == ["h", "shift-h"])
    }

    @Test func caseDoesNotAffectPlacement() {
        // Keys are written by hand in the config, so casing varies.
        #expect(order(["Shift-H", "h"]) == ["h", "Shift-H"])
    }

    @Test func sortingBindingsKeepsTheirActions() {
        // The sort reorders rows; it must not disturb what they do.
        let bindings: [PanewrightConfig.Binding] = [
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "0", action: .workspace(0)),
            .init(key: "1", action: .workspace(1)),
        ]
        let sorted = BindingOrder.sorted(bindings)
        #expect(sorted.map(\.key) == ["0", "1", "shift-1"])
        #expect(sorted[2].actions == [.moveToWorkspace(1)])
    }

    @Test func anEmptyListIsFine() {
        #expect(BindingOrder.sorted([]).isEmpty)
    }
}
