import Testing

@testable import PanewrightCore

@Suite struct BindingConflictTests {
    @Test func flagsDuplicateKeysAndSystemChords() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),
            .init(key: "1", action: .workspace(9)),   // duplicate
            .init(key: "space", action: .fullscreen), // ctrl-cmd-space = Emoji picker
            .init(key: "j", action: .focus(.down)),
        ]
        let conflicts = BindingConflicts.find(in: config)
        #expect(conflicts.count == 2)
        // The duplicate names both actions, so it's obvious which one wins.
        let duplicate = conflicts.first { $0.key == "1" }
        #expect(duplicate?.summary.contains("bound twice") == true)
        #expect(duplicate?.summary.contains("workspace 9") == true)
        // The system chord names its owner rather than just saying "conflict".
        #expect(conflicts.first { $0.key == "space" }?.summary.contains("Emoji") == true)
        // A clean binding isn't flagged.
        #expect(!conflicts.contains { $0.key == "j" })
    }

    @Test func modeKeysAreScopedAndNeverSystemChords() {
        var config = PanewrightConfig.default
        config.bindings = []
        config.modes = [
            .init(name: "resize", bindings: [
                .init(key: "h", action: .resize(.width, -50)),
                .init(key: "h", action: .resize(.width, 50)),
            ])
        ]
        let conflicts = BindingConflicts.find(in: config)
        // Same key in different modes is fine; the same key twice in one is not.
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.scope == "resize")
        // Mode keys are bare, so they can't collide with a macOS chord.
        #expect(conflicts.allSatisfy { if case .duplicate = $0.kind { true } else { false } })
    }

    @Test func defaultsHaveOneKnownSystemCollision() {
        // Found by this detector on its first run: the default $mod+f
        // (fullscreen) becomes ctrl-cmd-f, which is macOS's own "Enter Full
        // Screen". Apps with that menu item swallow it before AeroSpace sees
        // it. Asserted rather than hidden so the decision to rebind is
        // deliberate — and so a NEW conflict still fails this test.
        let conflicts = BindingConflicts.find(in: .default)
        let system = conflicts.filter { if case .systemShortcut = $0.kind { true } else { false } }
        #expect(system.count == 1)
        #expect(system.first?.key == "f")
        #expect(system.first?.summary.contains("Enter Full Screen") == true)

        // And the ergonomics check measures the other half of the problem:
        // under the ctrl-cmd default, every $mod+Shift binding is a
        // three-modifier stretch. That count is the case for replacing them
        // with a mode — it should go DOWN, never up.
        let awkward = conflicts.filter { if case .awkward = $0.kind { true } else { false } }
        #expect(awkward.count == 20)
    }
}

@Suite struct BindingConflictModifierTests {
    @Test func theSameKeyConflictsOnlyUnderSomeModifiers() {
        // $mod+f is fine or broken depending entirely on the modifier: ctrl-cmd-f
        // is macOS's Enter Full Screen, alt-f is nobody's. Conflicts must be
        // judged on the resolved chord, never the bare key.
        var clashing = PanewrightConfig.default
        clashing.modifier = .ctrlCmd
        clashing.bindings = [.init(key: "f", action: .fullscreen)]
        #expect(BindingConflicts.find(in: clashing).count == 1)

        var fine = clashing
        fine.modifier = .alt
        #expect(BindingConflicts.find(in: fine).isEmpty)

        var hyper = clashing
        hyper.modifier = .hyper
        #expect(BindingConflicts.find(in: hyper).isEmpty)
    }
}

@Suite struct ErgonomicsWarningTests {
    @Test func flagsThreeModifierChordsAndNamesTheFix() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),          // ⌃⌘1 — fine
            .init(key: "shift-1", action: .moveToWorkspace(1)),  // ⌃⌘⇧1 — a stretch
        ]
        let awkward = BindingConflicts.awkwardChords(in: config)
        #expect(awkward.count == 1)
        #expect(awkward.first?.key == "shift-1")
        #expect(awkward.first?.summary.contains("3 modifiers") == true)
        // The warning has to name the remedy, not just the problem.
        #expect(awkward.first?.summary.contains("mode") == true)
    }

    @Test func oneKeyAndSingleModifierSetupsAreNeverAwkward() {
        var config = PanewrightConfig.default
        config.bindings = [.init(key: "shift-1", action: .moveToWorkspace(1))]
        // Caps Lock hyper is one physical key, so ⇧ on top is still two fingers.
        config.modifier = .hyper
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
        // A single modifier plus shift is two keys — also fine.
        config.modifier = .alt
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
        // Leader style holds nothing at all.
        config.modifier = .leader
        #expect(BindingConflicts.awkwardChords(in: config).isEmpty)
    }
}

/// The conflicts list is rendered as rows and dismissed one at a time, so each
/// conflict has to be a distinct, stably-addressable thing.
@Suite struct ConflictIdentityTests {
    @Test func oneKeyHittingTwoProblemsProducesTwoDistinctRows() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "shift-1", action: .moveToWorkspace(2)),
        ]
        let conflicts = BindingConflicts.find(in: config)
        // Bound twice AND a three-modifier stretch: two different problems
        // with two different fixes, so two rows.
        #expect(conflicts.count == 2)
        // Distinct ids, or SwiftUI collapses them and "Ignore" hits the wrong one.
        #expect(Set(conflicts.map(\.id)).count == 2)
    }

    @Test func aKeyBoundTwiceIsOnlyOneErgonomicsComplaint() {
        // The stretch is a property of the chord, not of each binding on it —
        // listing it once per binding would make one fix look like two.
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "shift-h", action: .move(.left)),
            .init(key: "shift-h", action: .move(.right)),
            .init(key: "shift-j", action: .move(.down)),
        ]
        #expect(BindingConflicts.awkwardChords(in: config).count == 2)
    }

    @Test func conflictsReadAsKeycapsNotWireSyntax() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [.init(key: "shift-1", action: .moveToWorkspace(1))]
        // "ctrl-cmd-shift-1" is how it's stored; ⌃⌘⇧1 is what's on the keys.
        #expect(BindingConflicts.awkwardChords(in: config).first?.display == "⌃⌘⇧1")
    }

    @Test func modeConflictsAreLabeledWithTheirMode() {
        var config = PanewrightConfig.default
        config.bindings = []
        config.modes = [
            .init(name: "resize", bindings: [
                .init(key: "h", action: .resize(.width, -50)),
                .init(key: "h", action: .resize(.width, 50)),
            ])
        ]
        // Without the scope, "H" alone would send someone hunting through the
        // top-level bindings for a key that isn't there.
        #expect(BindingConflicts.find(in: config).first?.display == "resize mode: H")
    }
}

/// "Ignore" has to be a real answer: it silences the row AND the bar chip,
/// and it survives a restart.
@Suite struct IgnoredConflictTests {
    private var duplicated: PanewrightConfig {
        var config = PanewrightConfig.default
        config.modifier = .alt  // keeps the ergonomics warnings out of the count
        config.bindings = [
            .init(key: "1", action: .workspace(1)),
            .init(key: "1", action: .workspace(9)),
        ]
        config.modes = []
        return config
    }

    @Test func ignoringDropsItFromActiveButNotFromTheFullList() {
        var config = duplicated
        let conflict = BindingConflicts.find(in: config)[0]
        config.ignoredConflicts = [conflict.id]
        #expect(BindingConflicts.active(in: config).isEmpty)
        // Still findable, so the window can offer "Stop Ignoring".
        #expect(BindingConflicts.find(in: config).count == 1)
    }

    @Test func anIgnoredConflictSurvivesTheConfigFile() throws {
        var config = duplicated
        config.ignoredConflicts = ["main/1/duplicate"]
        let reparsed = try ConfigParser.parse(toml: PanewrightConfigSerializer.emit(config))
        #expect(reparsed.ignoredConflicts == ["main/1/duplicate"])
        // And it still matches the conflict it was recorded for — the id has
        // to be stable across a write/read cycle or the ignore silently lapses.
        #expect(BindingConflicts.active(in: reparsed).isEmpty)
    }
}

/// The bar chip is the only conflict surface most people will see.
@Suite struct ConflictChipTests {
    @Test func theChipIsAbsentWhenTheKeymapIsClean() throws {
        var config = PanewrightConfig.default
        config.modifier = .alt
        config.bindings = [.init(key: "j", action: .focus(.down))]
        config.modes = []
        #expect(BindingConflicts.active(in: config).isEmpty)
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        // A warning that's always there is wallpaper.
        #expect(!rc.contains("--add item conflicts"))
    }

    @Test func theChipCountsWhatTheWindowWouldList() throws {
        let config = PanewrightConfig.default
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        // Rows, not findings — the two numbers have to agree or neither is
        // believable.
        let count = BindingConflicts.rows(in: config).count
        #expect(count > 0)
        #expect(rc.contains("label=\"⚠ \(count)\""))
        #expect(rc.contains("panewright://conflicts"))
    }

    @Test func aFreshInstallDoesNotCryWolf() throws {
        // The default keymap has 21 findings but only 2 decisions: rebind the
        // macOS collision, and deal with the three-modifier stretches as a
        // group. A chip reading ⚠ 21 on day one is how a warning becomes
        // wallpaper.
        let config = PanewrightConfig.default
        #expect(BindingConflicts.find(in: config).count == 21)
        #expect(BindingConflicts.rows(in: config).count == 2)
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        #expect(rc.contains("label=\"⚠ 2\""))
    }

    @Test func ignoringEveryConflictTakesTheChipDown() throws {
        var config = PanewrightConfig.default
        config.ignoredConflicts = BindingConflicts.find(in: config).map(\.id)
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        // Dismissing a warning that keeps glowing is worse than no warning.
        #expect(!rc.contains("--add item conflicts"))
    }
}

/// Rows are units of *fixing*, not units of finding.
@Suite struct ConflictGroupingTests {
    @Test func theStretchesCollapseIntoOneRowThatNamesThemAll() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "shift-2", action: .moveToWorkspace(2)),
            .init(key: "shift-h", action: .move(.left)),
        ]
        config.modes = []
        let rows = BindingConflicts.rows(in: config)
        #expect(rows.count == 1)
        guard case .ergonomics(let chords, let modifiers, _) = rows[0].content else {
            Issue.record("expected the stretches to be grouped")
            return
        }
        #expect(modifiers == 3)
        // Grouped, but still specific about which keys — otherwise the row is
        // a number with no way to act on it.
        #expect(chords == ["⌃⌘⇧1", "⌃⌘⇧2", "⌃⌘⇧H"])
        #expect(rows[0].title == "3 bindings")
        // The advice was written for one chord; a row about three has to read
        // as one sentence about three.
        #expect(rows[0].detail.contains("reach them"))
        #expect(!rows[0].detail.contains("reach it"))
        // And it carries every id, so one "Ignore" silences the whole group.
        #expect(rows[0].conflictIDs.count == 3)
    }

    @Test func aLoneStretchStaysItsOwnRow() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [.init(key: "shift-1", action: .moveToWorkspace(1))]
        config.modes = []
        let rows = BindingConflicts.rows(in: config)
        #expect(rows.count == 1)
        // Grouping one item just hides it behind a count.
        guard case .single = rows[0].content else {
            Issue.record("a single stretch should not be grouped")
            return
        }
        #expect(rows[0].title == "⌃⌘⇧1")
    }

    @Test func breakageNeverGetsFoldedIntoTheGroup() {
        // Each duplicate and each macOS collision has its own distinct fix, so
        // they stay one row apiece however many there are.
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),
            .init(key: "1", action: .workspace(9)),
            .init(key: "f", action: .fullscreen),
            .init(key: "space", action: .fullscreen),
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "shift-2", action: .moveToWorkspace(2)),
        ]
        config.modes = []
        let rows = BindingConflicts.rows(in: config)
        // 1 duplicate + 2 system collisions + 1 grouped ergonomics row.
        #expect(rows.count == 4)
        #expect(rows.filter { if case .ergonomics = $0.content { true } else { false } }.count == 1)
    }

    @Test func ignoringAGroupSilencesEveryStretchInIt() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "shift-2", action: .moveToWorkspace(2)),
        ]
        config.modes = []
        let group = BindingConflicts.rows(in: config)[0]
        config.ignoredConflicts = group.conflictIDs
        // A row that stays put after you dismiss it isn't a button.
        #expect(BindingConflicts.rows(in: config).isEmpty)
        // And it comes back as one row, not two, when un-ignored.
        let ignoredIDs = Set(config.ignoredConflicts)
        let ignoredRows = BindingConflicts.rows(
            from: BindingConflicts.find(in: config).filter { ignoredIDs.contains($0.id) })
        #expect(ignoredRows.count == 1)
    }

    @Test func onlyModifierProblemsOfferToChangeTheModifier() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "1", action: .workspace(1)),
            .init(key: "1", action: .workspace(9)),
        ]
        config.modes = []
        let duplicate = BindingConflicts.rows(in: config)[0]
        // Swapping the mod key does nothing about a key bound twice.
        #expect(!duplicate.implicatesModifier)
        #expect(duplicate.rebindTarget == "1")
    }

    @Test func aGroupedRowHasNoSingleBindingToJumpTo() {
        var config = PanewrightConfig.default
        config.modifier = .ctrlCmd
        config.bindings = [
            .init(key: "shift-1", action: .moveToWorkspace(1)),
            .init(key: "shift-2", action: .moveToWorkspace(2)),
        ]
        config.modes = []
        let group = BindingConflicts.rows(in: config)[0]
        #expect(group.rebindTarget == nil)
        #expect(group.implicatesModifier)
    }
}

@Suite struct ConflictChipPlacementTests {
    @Test func theChipSitsOutsideTheTodoCluster() throws {
        var config = PanewrightConfig.default
        config.todo.enabled = true
        let rc = try SketchyBarConfigEmitter.emit(config).sketchybarrc
        guard let chip = rc.range(of: "--add item conflicts"),
            let todo = rc.range(of: "--add item todo right")
        else {
            Issue.record("expected both the chip and the to-do anchor")
            return
        }
        // SketchyBar orders a side by insertion and the to-do plugin grows its
        // pills leftward from the anchor, so a chip added afterwards lands
        // between the "+" and the first task and splits the group.
        #expect(chip.lowerBound < todo.lowerBound)
    }
}
