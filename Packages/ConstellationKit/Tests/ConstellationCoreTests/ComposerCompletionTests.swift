import Foundation
import Testing
@testable import ConstellationCore

@Suite struct ComposerTokenTests {
    @Test func aLeadingSlashIsACommandUntilASpace() {
        #expect(ComposerToken.trailing(in: "/") == ComposerToken(kind: .command, query: "", offset: 0))
        #expect(ComposerToken.trailing(in: "  /rev") == ComposerToken(kind: .command, query: "rev", offset: 2))
        #expect(ComposerToken.trailing(in: "/review now") == nil)
        #expect(ComposerToken.trailing(in: "fix /tmp") == nil)
    }

    @Test func anAtAfterASpaceIsAMention() {
        #expect(ComposerToken.trailing(in: "@") == ComposerToken(kind: .mention, query: "", offset: 0))
        #expect(ComposerToken.trailing(in: "look at @src/ma") == ComposerToken(kind: .mention, query: "src/ma", offset: 8))
        #expect(ComposerToken.trailing(in: "mail me@example.com") == nil)
        #expect(ComposerToken.trailing(in: "look at @src/main.swift ") == nil)
    }

    @Test func replacingKeepsTheTextBefore() throws {
        let mention = try #require(ComposerToken.trailing(in: "explain @ma"))
        #expect(mention.replacing(in: "explain @ma", with: "@App/main.swift ") == "explain @App/main.swift ")
        let command = try #require(ComposerToken.trailing(in: " /co"))
        #expect(command.replacing(in: " /co", with: "/compact ") == " /compact ")
    }
}

@Suite struct SlashCommandTests {
    @Test func insertionDependsOnTheProvider() {
        let skill = SlashCommand(name: "review", description: "", kind: .skill, scope: .user)
        #expect(skill.insertion(for: .claudeCode) == "/review ")
        #expect(skill.insertion(for: .codex) == "$review ")
    }

    @Test func findsCodexSkillMentions() {
        #expect(SlashCommand.codexSkillMentions(in: "$review the diff then $lint, and $review again") == ["review"])
        #expect(SlashCommand.codexSkillMentions(in: "costs $5 and $plugin:skill") == ["5", "plugin:skill"])
        #expect(SlashCommand.codexSkillMentions(in: "echo a$b") == [])
    }
}

@Suite struct FuzzyMatchTests {
    @Test func matchesSubsequencesIgnoringCase() {
        #expect(FuzzyMatch.score("acs", in: "App/Chat/ChatComposer.swift") != nil)
        #expect(FuzzyMatch.score("xyz", in: "App/Chat/ChatComposer.swift") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func prefersFileNamesWordStartsAndShortPaths() {
        let files = [
            "Packages/ConstellationKit/Sources/ConstellationCore/Session.swift",
            "App/Answering/SessionView.swift",
            "docs/session-notes/overview.md",
            "App/Chat/ChatComposer.swift",
        ]
        #expect(FuzzyMatch.rank("sessview", files, limit: 1) == ["App/Answering/SessionView.swift"])
        #expect(FuzzyMatch.rank("composer", files, limit: 1) == ["App/Chat/ChatComposer.swift"])
        #expect(FuzzyMatch.rank("session", files, limit: 4).first == "App/Answering/SessionView.swift")
        #expect(FuzzyMatch.rank("", files, limit: 2) == Array(files.prefix(2)))
    }
}

@Suite struct PromptHistoryTests {
    @Test func walksOlderThenBackToEmpty() {
        var walk = PromptHistoryWalk(entries: ["newest", "middle", "oldest"])
        #expect(walk.current == nil)
        #expect(walk.older() == "newest")
        #expect(walk.older() == "middle")
        #expect(walk.older() == "oldest")
        #expect(walk.older() == nil)
        #expect(walk.current == "oldest")
        #expect(walk.newer() == "middle")
        #expect(walk.newer() == "newest")
        #expect(walk.newer() == nil)
        #expect(walk.index == nil)
    }

    @Test func recordingMovesARepeatToTheFront() {
        #expect(PromptHistory.recording(" b ", in: ["a", "b", "c"]) == ["b", "a", "c"])
        #expect(PromptHistory.recording("   ", in: ["a"]) == ["a"])
        #expect(PromptHistory.recording("x", in: Array(repeating: "y", count: PromptHistory.limit)).count == PromptHistory.limit)
    }
}
