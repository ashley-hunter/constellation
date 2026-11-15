import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct ClaudeCommandCatalogTests {
    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func findsCommandsAndSkillsInRepoAndHome() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (repo, home) = (sandbox.appending(path: "repo"), sandbox.appending(path: "home"))
        try write("---\ndescription: Ship it\n---\nRun the release.", to: ".claude/commands/release.md", in: repo)
        try write("# Make a component\nBody", to: ".claude/commands/frontend/component.md", in: repo)
        try write("Home release", to: ".claude/commands/release.md", in: home)
        try write("---\nname: grill-me\ndescription: >\n  Interview the user\n  relentlessly\n---\n", to: ".claude/skills/grill/SKILL.md", in: home)
        try write("no skill file here", to: ".claude/skills/empty/README.md", in: home)

        let commands = ClaudeCommandCatalog.commands(repo: repo, home: home)
        let byName = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        #expect(byName["release"]?.scope == .repo)
        #expect(byName["release"]?.description == "Ship it")
        #expect(byName["frontend:component"]?.description == "Make a component")
        #expect(byName["grill-me"]?.kind == .skill)
        #expect(byName["grill-me"]?.description == "Interview the user relentlessly")
        #expect(byName["empty"] == nil)
        #expect(commands.count { $0.name == "release" } == 1)
        #expect(commands.last?.kind == .builtIn)
        #expect(commands.contains { $0.name == "compact" })
    }

    @Test func frontMatterHandlesQuotesAndMissingBlocks() {
        #expect(ClaudeCommandCatalog.frontMatter(of: "---\nname: \"a b\"\nallowed-tools: Bash\n---\nbody") == ["name": "a b", "allowed-tools": "Bash"])
        #expect(ClaudeCommandCatalog.frontMatter(of: "no front matter") == [:])
        #expect(ClaudeCommandCatalog.description(of: "---\nname: x\n---\n\n## Heading\ntext") == "Heading")
    }
}

@Suite struct CodexSkillTests {
    private let skills = [SlashCommand(name: "review", description: "", kind: .skill, scope: .repo, path: "/repo/.codex/skills/review/SKILL.md")]

    private func encoded(_ items: [CodexUserInput]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(items), as: UTF8.self)
    }

    @Test func mentionedSkillsBecomeSkillItems() throws {
        let items = CodexUserInput.items(for: UserMessage(text: "$review the diff, ignore $other"), skills: skills)
        #expect(try encoded(items) == #"[{"text":"$review the diff, ignore $other","type":"text"},{"name":"review","path":"/repo/.codex/skills/review/SKILL.md","type":"skill"}]"#)
        #expect(CodexUserInput.items(for: UserMessage(text: "no skills"), skills: skills) == [.text("no skills")])
    }

    @Test func skillsListResponseBecomesMenuEntries() throws {
        let json = #"""
        {"data":[{"cwd":"/repo","errors":[],"skills":[
          {"name":"sys","description":"System skill","path":"/s/SKILL.md","scope":"system","enabled":true},
          {"name":"off","description":"Disabled","path":"/o/SKILL.md","scope":"user","enabled":false},
          {"name":"mine","description":"Long","shortDescription":"Short","path":"/r/SKILL.md","scope":"repo","enabled":true}
        ]}]}
        """#
        let response = try JSONDecoder().decode(CodexSkillsListResponse.self, from: Data(json.utf8))
        let commands = response.commands(for: "/repo")
        #expect(commands.map(\.name) == ["mine", "sys"])
        #expect(commands.first?.description == "Short")
        #expect(commands.first?.scope == .repo)
    }
}
