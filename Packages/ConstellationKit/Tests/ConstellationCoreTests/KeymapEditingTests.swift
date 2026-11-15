import Testing
@testable import ConstellationCore

private func strokes(_ spec: String) -> [KeyStroke] {
    KeyBinding(spec).strokes
}

private func keys(_ config: KeysConfig, _ action: String, _ argument: String? = nil, global: Bool = false) -> [[KeyStroke]] {
    Keymap(defaults: testDefaults, config: config).entries(for: action, argument: argument, global: global).map(\.rule.strokes)
}

@Suite struct KeymapEditingTests {
    private let handWritten = """
    # My keys

    # Moving
    bind = , Q, session.stop   # quit-ish
    unbind = , Y
    """

    @Test func rebindingWritesOnlyTheOverride() {
        var config = KeysConfig(parsing: "")
        config.setKeys([strokes("cmd+shift+c")], for: "git.commit", argument: nil, defaults: testDefaults)
        #expect(config.text == """
        unbind = , CTRL+X C, git.commit
        bind = CMD SHIFT, C, git.commit

        """)
        #expect(keys(config, "git.commit") == [strokes("cmd+shift+c")])
    }

    @Test func addingAKeyKeepsTheDefault() {
        var config = KeysConfig(parsing: "")
        config.setKeys([strokes("ctrl+x c"), strokes("cmd+shift+c")], for: "git.commit", argument: nil, defaults: testDefaults)
        #expect(config.text == "bind = CMD SHIFT, C, git.commit\n")
    }

    @Test func settingTheDefaultKeysBackLeavesNoLines() {
        var config = KeysConfig(parsing: handWritten)
        config.setKeys([strokes("q")], for: "git.commit", argument: nil, defaults: testDefaults)
        config.setKeys([strokes("ctrl+x c")], for: "git.commit", argument: nil, defaults: testDefaults)
        #expect(config.text == KeysConfig(parsing: handWritten).text)
    }

    @Test func editsKeepCommentsAndOrdering() {
        var config = KeysConfig(parsing: handWritten)
        config.setKeys([strokes("z")], for: "focus.move", argument: "down", defaults: testDefaults)
        #expect(config.text == handWritten + """

        unbind = , J, focus.move, down
        unbind = , DOWN, focus.move, down
        bind = , Z, focus.move, down

        """)
    }

    @Test func rebindingReplacesTheActionsEarlierLines() {
        var config = KeysConfig(parsing: handWritten)
        config.setKeys([strokes("w")], for: "session.stop", argument: nil, defaults: testDefaults)
        #expect(config.text == """
        # My keys

        # Moving
        unbind = , Y
        unbind = , X, session.stop
        bind = , W, session.stop

        """)
    }

    @Test func clearingUnbinds() {
        var config = KeysConfig(parsing: "")
        config.setKeys([], for: "session.stop", argument: nil, defaults: testDefaults)
        #expect(config.text == "unbind = , X, session.stop\n")
        #expect(keys(config, "session.stop").isEmpty)
    }

    @Test func resetRemovesTheActionsLines() {
        var config = KeysConfig(parsing: handWritten)
        config.reset("session.stop", argument: nil, defaults: testDefaults)
        #expect(!config.text.contains("Q"))
        #expect(config.text.contains("unbind = , Y"))
        #expect(keys(config, "session.stop") == [strokes("x")])
    }

    @Test func resetSplitsAnUnbindSharedWithOtherActions() {
        var config = KeysConfig(parsing: "unbind = , R   # no r at all\nbind = , Q, x")
        config.reset("session.retry", argument: nil, defaults: testDefaults)
        #expect(config.text == "unbind = , R, session.resume  # no r at all\nbind = , Q, x\n")
        #expect(keys(config, "session.retry") == [strokes("r")])
        #expect(keys(config, "session.resume").isEmpty)
    }

    @Test func resetDropsAnUnbindOnlyThisActionUsed() {
        var config = KeysConfig(parsing: "unbind = , X\n")
        config.reset("session.stop", argument: nil, defaults: testDefaults)
        #expect(config.text == "")
    }

    @Test func resetKeepsAnArgumentlessUnbindForOtherArguments() {
        var config = KeysConfig(parsing: "unbind = , J, focus.move\n")
        config.setKeys([strokes("z")], for: "focus.move", argument: "up", defaults: testDefaults)
        #expect(config.text.hasPrefix("unbind = , J, focus.move\n"))
        #expect(!keys(config, "focus.move", "down").contains(strokes("j")))
    }

    @Test func resetSplitsAnArgumentlessUnbindThatReachesThisArgument() {
        var config = KeysConfig(parsing: "unbind = , J, focus.move\n")
        config.reset("focus.move", argument: "down", defaults: testDefaults)
        #expect(keys(config, "focus.move", "down").contains(strokes("j")))
    }

    @Test func replacingAConflictFreesTheKey() {
        var config = KeysConfig(parsing: "bind = , Q, git.push\n")
        config.removeConflicts(with: strokes("q"), keeping: "git.commit", argument: nil, defaults: testDefaults)
        config.setKeys([strokes("q")], for: "git.commit", argument: nil, defaults: testDefaults)
        #expect(config.text == "unbind = , CTRL+X C, git.commit\nbind = , Q, git.commit\n")

        var defaultsClash = KeysConfig(parsing: "")
        defaultsClash.removeConflicts(with: strokes("x"), keeping: "git.commit", argument: nil, defaults: testDefaults)
        defaultsClash.setKeys([strokes("x")], for: "git.commit", argument: nil, defaults: testDefaults)
        let keymap = Keymap(defaults: testDefaults, config: defaultsClash)
        #expect(keymap.match(strokes("x")) == .exact([Keymap.Entry(KeyRule(strokes("x"), "git.commit"), source: .file(line: 3))]))
        #expect(keymap.entries(for: "session.stop", argument: nil).isEmpty)
    }

    @Test func globalsToggleOffAndBackOn() {
        var config = KeysConfig(parsing: "")
        config.setKeys([], for: "app.summon", argument: nil, global: true, defaults: testDefaults)
        #expect(config.text == "unglobal = ALT, SPACE, app.summon\n")
        #expect(keys(config, "app.summon", global: true).isEmpty)
        #expect(keys(config, "session.stop") == [strokes("x")])
        config.reset("app.summon", argument: nil, global: true, defaults: testDefaults)
        #expect(config.text == "")
    }

    @Test func resetAllKeepsComments() {
        var config = KeysConfig(parsing: handWritten)
        config.resetAll()
        #expect(config.text == "# My keys\n\n# Moving\n")
    }

    @Test func templateIsAllCommentsAndListsTheDefaults() {
        let text = KeysConfig.template(defaults: testDefaults, titles: ["git.commit": "Commit"])
        let config = KeysConfig(parsing: text)
        #expect(config.directives.isEmpty)
        #expect(config.problems.isEmpty)
        #expect(text.contains("# bind = , CTRL+X C, git.commit"))
        #expect(text.contains("# Commit"))
        #expect(text.contains("# global = ALT, SPACE, app.summon"))
        // Uncommenting a default line gives a working binding.
        let line = text.split(separator: "\n").first { $0.contains("CTRL+X C, git.commit") }!.dropFirst(2)
        #expect(KeysConfig(parsing: String(line)).directives.map(\.directive) == [.bind(KeyRule(strokes("ctrl+x c"), "git.commit"), global: false)])
    }
}
