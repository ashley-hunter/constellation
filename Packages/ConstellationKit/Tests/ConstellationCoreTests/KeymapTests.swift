import Testing
@testable import ConstellationCore

private func rule(_ spec: String, _ action: String, _ argument: String? = nil) -> KeyRule {
    KeyRule(KeyBinding(spec).strokes, action, argument: argument)
}

private func strokes(_ spec: String) -> [KeyStroke] {
    KeyBinding(spec).strokes
}

let testDefaults = KeymapDefaults(
    bindings: [
        rule("y", "ask.answer", "y"),
        rule("1", "ask.answer", "1"),
        rule("j", "focus.move", "down"),
        rule("k", "focus.move", "up"),
        rule("down", "focus.move", "down"),
        rule("x", "session.stop"),
        rule("r", "session.retry"),
        rule("r", "session.resume"),
        rule("d d", "session.archive"),
        rule("g g", "focus.first"),
        rule("ctrl+x c", "git.commit"),
        rule("ctrl+x space", "tile.open"),
        rule("ctrl+x shift+p", "git.pr"),
        rule("1", "arrange.by", "1"),
        rule("cmd+k", "palette.open"),
    ],
    globals: [
        rule("alt+space", "app.summon"),
        rule("alt+1", "tile.focus", "1"),
    ]
)

@Suite struct KeymapResolutionTests {
    /// A keys.conf from when there was a Vim keymap too still loads, its style and leader passed over.
    @Test func oldStyleAndLeaderLinesChangeNothing() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "style = vim\nleader = CTRL+A"), knownActions: [])
        #expect(keymap.problems.isEmpty)
        #expect(keymap.bindings.map(\.rule) == testDefaults.bindings)
    }

    @Test func fileBindsComeFirstAndAddToTheDefaults() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "\n\nbind = , Q, session.stop"))
        #expect(keymap.bindings.first == Keymap.Entry(rule("q", "session.stop"), source: .file(line: 3)))
        #expect(keymap.entries(for: "session.stop", argument: nil).map(\.rule.strokes) == [strokes("q"), strokes("x")])
    }

    @Test func untargetedUnbindDropsEveryActionOnTheKey() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "unbind = , R"))
        #expect(keymap.entries(for: "session.retry", argument: nil).isEmpty)
        #expect(keymap.entries(for: "session.resume", argument: nil).isEmpty)
    }

    @Test func targetedUnbindDropsOnlyThatAction() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "unbind = , R, session.retry"))
        #expect(keymap.entries(for: "session.retry", argument: nil).isEmpty)
        #expect(keymap.entries(for: "session.resume", argument: nil).count == 1)
        let digits = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "unbind = , 1, arrange.by"))
        #expect(digits.entries(for: "arrange.by", argument: "1").isEmpty)
        #expect(digits.entries(for: "ask.answer", argument: "1").count == 1)
    }

    @Test func unbindOnlyReachesBindsAboveIt() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: """
        bind = , Q, session.stop
        unbind = , Q
        bind = , W, session.stop
        unbind = , W, git.commit
        """))
        #expect(keymap.entries(for: "session.stop", argument: nil).map(\.rule.strokes) == [strokes("w"), strokes("x")])
    }

    @Test func unknownActionsAreProblemsWithTheirLine() {
        let keymap = Keymap(
            defaults: testDefaults,
            config: KeysConfig(parsing: "bind = , Q, session.stop\nbind = , W, nope.nothing\nfrobnicate = yes"),
            knownActions: ["session.stop"]
        )
        #expect(keymap.problems.map(\.line) == [2, 3])
        #expect(keymap.problems[0].message == "unknown action \u{201C}nope.nothing\u{201D}")
        #expect(keymap.bindings.first?.rule == rule("q", "session.stop"))
    }

    /// A keys.conf from before bloom was removed still loads: the old bind is a notice, not a break.
    @Test func aRetiredActionIsANoticeAndTheRestStillApplies() {
        let keymap = Keymap(
            defaults: testDefaults,
            config: KeysConfig(parsing: "bind = , SPACE, tile.bloom\nbind = , Q, session.stop"),
            knownActions: ["session.stop", "tile.open"]
        )
        #expect(keymap.problems.map(\.line) == [1])
        #expect(keymap.problems[0].message == "unknown action \u{201C}tile.bloom\u{201D}")
        #expect(keymap.bindings.contains { $0.rule == rule("q", "session.stop") })
        #expect(!keymap.bindings.contains { $0.rule.action == "tile.bloom" })
    }

    @Test func globalsResolveSeparately() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: """
        unglobal = ALT, SPACE
        global = CTRL ALT, C, app.summon
        unbind = ALT, 1
        """))
        #expect(keymap.globals.map(\.rule) == [rule("ctrl+alt+c", "app.summon"), rule("alt+1", "tile.focus", "1")])
    }

    @Test func customizedMeansDifferentFromTheDefaults() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "bind = , Q, session.stop\nbind = , X, session.stop"))
        #expect(keymap.isCustomized("session.stop", argument: nil, defaults: testDefaults))
        #expect(!keymap.isCustomized("git.commit", argument: nil, defaults: testDefaults))
        let same = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "bind = , X, session.stop"))
        #expect(!same.isCustomized("session.stop", argument: nil, defaults: testDefaults))
    }
}

@Suite struct KeymapMatchingTests {
    let keymap = Keymap(defaults: testDefaults)

    @Test func singleKeysRunEveryActionOnThemInOrder() {
        #expect(keymap.match(strokes("1")) == .exact([Keymap.Entry(rule("1", "ask.answer", "1")), Keymap.Entry(rule("1", "arrange.by", "1"))]))
        #expect(keymap.match(strokes("z")) == .none)
    }

    @Test func sequences() {
        #expect(keymap.match(strokes("ctrl+x")) == .prefix(exact: []))
        #expect(keymap.match(strokes("ctrl+x c")) == .exact([Keymap.Entry(rule("ctrl+x c", "git.commit"))]))
        #expect(keymap.match(strokes("ctrl+x space")) == .exact([Keymap.Entry(rule("ctrl+x space", "tile.open"))]))
        #expect(keymap.match(strokes("ctrl+x P")) == .exact([Keymap.Entry(rule("ctrl+x shift+p", "git.pr"))]))
        #expect(keymap.match(strokes("d")) == .prefix(exact: []))
        #expect(keymap.match(strokes("d d")) == .exact([Keymap.Entry(rule("d d", "session.archive"))]))
    }

    @Test func aKeyThatIsBothABindingAndAPrefixWaits() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "bind = , G, focus.last"))
        #expect(keymap.match(strokes("g")) == .prefix(exact: [Keymap.Entry(rule("g", "focus.last"), source: .file(line: 1))]))
    }

    @Test func conflictsAreTheSameKeysOrAPrefix() {
        #expect(keymap.conflicts(with: strokes("x"), excluding: "git.commit", argument: nil).map(\.rule.action) == ["session.stop"])
        #expect(keymap.conflicts(with: strokes("d"), excluding: "git.commit", argument: nil).map(\.rule.action) == ["session.archive"])
        #expect(keymap.conflicts(with: strokes("ctrl+x c"), excluding: "git.commit", argument: nil).isEmpty)
        #expect(keymap.conflicts(with: strokes("ctrl+x"), excluding: "git.push", argument: nil).map(\.rule.action) == ["git.commit", "tile.open", "git.pr"])
        #expect(keymap.conflicts(with: strokes("ctrl+x c"), excluding: "git.push", argument: nil).map(\.rule.action) == ["git.commit"])
        #expect(keymap.conflicts(with: strokes("alt+space"), excluding: "x", argument: nil, global: true).map(\.rule.action) == ["app.summon"])
    }
}

@Suite struct KeySequencerTests {
    let keymap = Keymap(defaults: testDefaults)

    @Test func runsSingleKeysAtOnce() {
        var sequencer = KeySequencer()
        #expect(sequencer.feed(KeyStroke(key: "x"), in: keymap) == .run([Keymap.Entry(rule("x", "session.stop"))]))
        #expect(sequencer.pending.isEmpty)
    }

    @Test func waitsThroughASequence() {
        var sequencer = KeySequencer()
        #expect(sequencer.feed(KeyStroke(key: "x", modifiers: .control), in: keymap) == .wait(fallback: []))
        #expect(sequencer.pending == strokes("ctrl+x"))
        #expect(sequencer.feed(KeyStroke(key: "c"), in: keymap) == .run([Keymap.Entry(rule("ctrl+x c", "git.commit"))]))
        #expect(sequencer.pending.isEmpty)
    }

    @Test func aKeyThatBreaksTheSequenceStartsAfresh() {
        var sequencer = KeySequencer()
        _ = sequencer.feed(KeyStroke(key: "d"), in: keymap)
        #expect(sequencer.feed(KeyStroke(key: "j"), in: keymap) == .run([Keymap.Entry(rule("j", "focus.move", "down"))]))
        _ = sequencer.feed(KeyStroke(key: "d"), in: keymap)
        #expect(sequencer.feed(KeyStroke(key: "z"), in: keymap) == .unmatched)
        #expect(sequencer.pending.isEmpty)
    }

    @Test func timingOutRunsTheShorterBinding() {
        let keymap = Keymap(defaults: testDefaults, config: KeysConfig(parsing: "bind = , G, focus.last"))
        var sequencer = KeySequencer()
        #expect(sequencer.feed(KeyStroke(key: "g"), in: keymap) == .wait(fallback: [Keymap.Entry(rule("g", "focus.last"), source: .file(line: 1))]))
        #expect(sequencer.timeOut(in: keymap).map(\.rule.action) == ["focus.last"])
        #expect(sequencer.pending.isEmpty)
    }
}

@Suite struct JumpHintTests {
    @Test func oneLetterWhileTheyLast() {
        #expect(JumpHints.labels(count: 3) == ["a", "s", "d"])
        #expect(JumpHints.labels(count: 9) == JumpHints.homeRow)
        #expect(JumpHints.labels(count: 0).isEmpty)
        #expect(JumpHints.labels(count: 1) == ["a"])
        #expect(JumpHints.labels(count: JumpHints.homeRow.count + 1).count == JumpHints.homeRow.count + 1)
    }

    @Test func thenTwoLettersWithNoLabelStartingAnother() {
        let labels = JumpHints.labels(count: 12)
        #expect(labels == ["s", "d", "f", "g", "h", "j", "k", "l", "aa", "as", "ad", "af"])
        for many in [10, 30, 81, 100] {
            let labels = JumpHints.labels(count: many)
            #expect(labels.count == many)
            #expect(Set(labels).count == many)
            for label in labels {
                #expect(!labels.contains { $0 != label && $0.hasPrefix(label) })
            }
        }
    }

    @Test func resolvingTypedLetters() {
        let labels = JumpHints.labels(count: 12)
        #expect(JumpHints.resolve("s", among: labels) == .complete(0))
        #expect(JumpHints.resolve("a", among: labels) == .partial)
        #expect(JumpHints.resolve("ad", among: labels) == .complete(10))
        #expect(JumpHints.resolve("q", among: labels) == .none)
    }

    @Test func digitsNameTheFirstTenTiles() {
        #expect(JumpHints.index(ofDigit: "1") == 0)
        #expect(JumpHints.index(ofDigit: "0") == 9)
        #expect(JumpHints.index(ofDigit: "a") == nil)
    }
}
