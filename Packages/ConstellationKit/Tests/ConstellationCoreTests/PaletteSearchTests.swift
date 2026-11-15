import Testing
@testable import ConstellationCore

@Suite struct PaletteQueryTests {
    @Test func prefixesPickTheScope() {
        #expect(PaletteQuery("commit") == PaletteQuery(scope: .everything, text: "commit"))
        #expect(PaletteQuery("> arr ") == PaletteQuery(scope: .commands, text: "arr"))
        #expect(PaletteQuery("@ledger") == PaletteQuery(scope: .sessions, text: "ledger"))
        #expect(PaletteQuery("/rev") == PaletteQuery(scope: .slashCommands, text: "rev"))
        #expect(PaletteQuery("") == PaletteQuery(scope: .everything, text: ""))
    }

    @Test func transcriptsJoinFromThreeCharacters() {
        #expect(!PaletteQuery("lo").searchesTranscripts)
        #expect(PaletteQuery("log").searchesTranscripts)
        #expect(PaletteQuery("@log").searchesTranscripts)
        #expect(!PaletteQuery(">log").searchesTranscripts)
        #expect(!PaletteQuery("/log").searchesTranscripts)
    }
}

private extension PaletteQuery {
    init(scope: Scope, text: String) {
        self.init("")
        self.scope = scope
        self.text = text
    }
}

@Suite struct PaletteRankingTests {
    private struct Row {
        let key: String
        let title: String
        var keywords: [String] = []
    }

    private let rows = [
        Row(key: "git.commit", title: "Commit", keywords: ["git", "save"]),
        Row(key: "git.push", title: "Push", keywords: ["git", "upload"]),
        Row(key: "session.archive", title: "Archive", keywords: ["clean up", "remove"]),
        Row(key: "arrange.by:1", title: "Arrange by Project"),
    ]

    private func ranked(_ query: String, recents: [String] = []) -> [String] {
        PaletteRanking.rank(query, rows, recents: recents, key: \.key, title: \.title, keywords: \.keywords).map(\.key)
    }

    @Test func titlesAndKeywordsMatch() {
        #expect(ranked("cmt") == ["git.commit"])
        #expect(ranked("upload") == ["git.push"])
        #expect(ranked("git") == ["git.commit", "git.push"])
        #expect(ranked("zzz").isEmpty)
    }

    @Test func titleMatchesBeatKeywordMatches() {
        #expect(PaletteRanking.score("push", title: "Push")! > PaletteRanking.score("push", title: "Upload", keywords: ["push"])!)
    }

    @Test func anEmptyQueryKeepsTheOrderGiven() {
        #expect(ranked("") == rows.map(\.key))
    }

    @Test func recentRowsComeFirstNewestFirst() {
        #expect(ranked("", recents: ["arrange.by:1", "git.push"]) == ["arrange.by:1", "git.push", "git.commit", "session.archive"])
        #expect(ranked("a", recents: ["session.archive"]).first == "session.archive")
        // A recent row that doesn't match stays out.
        #expect(ranked("commit", recents: ["git.push"]) == ["git.commit"])
    }

    @Test func recordingMovesAKeyToTheFrontOnce() {
        #expect(PaletteRanking.recording("b", in: ["a", "b", "c"]) == ["b", "a", "c"])
        let full = (0..<PaletteRanking.recentsLimit).map(String.init)
        #expect(PaletteRanking.recording("new", in: full).count == PaletteRanking.recentsLimit)
    }
}
