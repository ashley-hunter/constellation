import Testing
@testable import ConstellationCore

private func strokes(_ spec: String) -> [KeyStroke] {
    KeyBinding(spec).strokes
}

@Suite struct KeyStrokeTests {
    @Test func specsReadCapitalsAsShift() {
        #expect(KeyStroke("J") == KeyStroke(key: "j", modifiers: .shift))
        #expect(KeyStroke("cmd+shift+c") == KeyStroke(key: "c", modifiers: [.command, .shift]))
        #expect(KeyStroke("hyper+c") == nil)
        #expect(KeyBinding("ctrl+x shift+p").strokes == [KeyStroke(key: "x", modifiers: .control), KeyStroke(key: "p", modifiers: .shift)])
    }

    @Test func onlyCommandChordsEscAndTabWorkWhileEditing() {
        #expect(KeyStroke("cmd+k")!.worksWhileEditing)
        #expect(KeyStroke("escape")!.worksWhileEditing)
        #expect(!KeyStroke("cmd+return")!.worksWhileEditing)
        #expect(!KeyStroke("cmd+delete")!.worksWhileEditing)
        #expect(!KeyStroke("cmd+shift+left")!.worksWhileEditing)
        #expect(KeyStroke("ctrl+cmd+left")!.worksWhileEditing)
        #expect(!KeyStroke("j")!.worksWhileEditing)
    }

    @Test func labels() {
        #expect(KeyBinding("cmd+shift+c").label == "⇧⌘C")
        #expect(KeyBinding("g g").label == "g g")
        #expect(KeyBinding("cmd+,").label == "⌘,")
    }
}

@Suite struct KeysConfigParsingTests {
    @Test func readsEveryDirective() {
        let config = KeysConfig(parsing: """
        bind = , J, focus.move, down
        bind = SHIFT, J, tile.move, down
        bind = , CTRL+X C, git.commit
        bind = CMD, 1, tile.focus, 1
        global = ALT, SPACE, app.summon
        unbind = , X
        unbind = , R, session.retry
        unglobal = ALT SHIFT, SPACE
        """)
        #expect(config.problems.isEmpty)
        #expect(config.directives.map(\.directive) == [
            .bind(KeyRule(strokes("j"), "focus.move", argument: "down"), global: false),
            .bind(KeyRule(strokes("J"), "tile.move", argument: "down"), global: false),
            .bind(KeyRule(strokes("ctrl+x c"), "git.commit"), global: false),
            .bind(KeyRule(strokes("cmd+1"), "tile.focus", argument: "1"), global: false),
            .bind(KeyRule(strokes("alt+space"), "app.summon"), global: true),
            .unbind(KeyTarget(strokes("x")), global: false),
            .unbind(KeyTarget(strokes("r"), action: "session.retry"), global: false),
            .unbind(KeyTarget(strokes("alt+shift+space")), global: true),
        ])
    }

    /// Left over from when there was a Vim keymap too: read as nothing, and kept as written.
    @Test func styleAndLeaderLinesArePassedOver() {
        let text = "style = vim\nleader = SPACE\nbind = , J, focus.move, down\n"
        let config = KeysConfig(parsing: text)
        #expect(config.problems.isEmpty)
        #expect(config.directives.map(\.line) == [3])
        #expect(config.text == text)
    }

    @Test func keysAreCaseInsensitiveAndShiftIsExplicit() {
        let lower = KeysConfig(parsing: "bind = shift, j, tile.move, down")
        let upper = KeysConfig(parsing: "bind = SHIFT, J, tile.move, down")
        #expect(lower.directives.map(\.directive) == upper.directives.map(\.directive))
    }

    @Test func sequencesAndNamedKeys() {
        let config = KeysConfig(parsing: """
        bind = , G G, focus.first
        bind = CMD, CMD+K S, app.settings
        bind = CMD, COMMA, app.settings
        bind = super_shift, return, tile.open
        bind = , ESC, back
        """)
        #expect(config.problems.isEmpty)
        #expect(config.directives.map(\.directive) == [
            .bind(KeyRule(strokes("g g"), "focus.first"), global: false),
            .bind(KeyRule(strokes("cmd+k cmd+s"), "app.settings"), global: false),
            .bind(KeyRule([KeyStroke(key: ",", modifiers: .command)], "app.settings"), global: false),
            .bind(KeyRule(strokes("cmd+shift+return"), "tile.open"), global: false),
            .bind(KeyRule(strokes("escape"), "back"), global: false),
        ])
    }

    @Test func badLinesReportTheirLineNumberAndTheRestApplies() {
        let config = KeysConfig(parsing: """
        # comment
        bind = LEADER, C, git.commit
        bind = HYPER, J, focus.move, down
        bind = , J
        bind = , FOO, back
        frobnicate = yes
        bind = , K, focus.move, up
        no equals here
        bind = LEADER, , git.commit
        """)
        #expect(config.problems.map(\.line) == [2, 3, 4, 5, 6, 8, 9])
        #expect(config.problems[0].description == "line 2: unknown modifier \u{201C}LEADER\u{201D}")
        #expect(config.problems[1].message.contains("HYPER"))
        #expect(config.problems[3].message.contains("FOO"))
        #expect(config.directives.map(\.directive) == [.bind(KeyRule(strokes("k"), "focus.move", argument: "up"), global: false)])
    }

    @Test func textRoundTripsExactly() {
        let text = """
        # My keys

        style = standard   # trying it out
        bind = , J, focus.move, down
          bind=SHIFT,J,tile.move,down
        not a directive

        """
        #expect(KeysConfig(parsing: text).text == text)
    }

    @Test func formatsInTheFileSyntax() {
        #expect(KeysConfig.format(.bind(KeyRule(strokes("cmd+shift+p"), "git.pr"), global: false)) == "bind = CMD SHIFT, P, git.pr")
        #expect(KeysConfig.format(.bind(KeyRule(strokes("j"), "focus.move", argument: "down"), global: false)) == "bind = , J, focus.move, down")
        #expect(KeysConfig.format(.bind(KeyRule(strokes("g g"), "focus.first"), global: false)) == "bind = , G G, focus.first")
        #expect(KeysConfig.format(.bind(KeyRule(strokes("cmd+k cmd+s"), "x"), global: false)) == "bind = CMD, CMD+K S, x")
        #expect(KeysConfig.format(.bind(KeyRule([KeyStroke(key: ",", modifiers: .command)], "app.settings"), global: false)) == "bind = CMD, COMMA, app.settings")
        #expect(KeysConfig.format(.bind(KeyRule(strokes("alt+space"), "app.summon"), global: true)) == "global = ALT, SPACE, app.summon")
        #expect(KeysConfig.format(.unbind(KeyTarget(strokes("r"), action: "session.retry"), global: false)) == "unbind = , R, session.retry")
    }

    @Test func formattedLinesParseBack() {
        let directives: [KeysConfig.Directive] = [
            .bind(KeyRule(strokes("ctrl+x shift+p"), "git.pr"), global: false),
            .bind(KeyRule(strokes("cmd+shift+1"), "tile.split", argument: "1"), global: false),
            .bind(KeyRule(strokes("cmd+k cmd+s"), "x"), global: false),
            .bind(KeyRule([KeyStroke(key: "+", modifiers: .command)], "zoom"), global: false),
            .bind(KeyRule([KeyStroke(key: "#")], "hash"), global: false),
            .unbind(KeyTarget(strokes("d d"), action: "session.archive"), global: false),
            .unbind(KeyTarget(strokes("alt+1"), action: "tile.focus", argument: "1"), global: true),
        ]
        for directive in directives {
            #expect(KeysConfig(parsing: KeysConfig.format(directive)).directives.map(\.directive) == [directive])
        }
    }
}
