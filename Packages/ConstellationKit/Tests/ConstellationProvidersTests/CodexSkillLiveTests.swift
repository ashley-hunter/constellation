import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// A repo skill found by `skills/list`, then run from a `$name` mention. Same switches as `CodexLiveTests`.
@Suite(.enabled(if: CodexLive.binary != nil && CodexLive.repo != nil), .timeLimit(.minutes(5)))
struct CodexSkillLiveTests {
    @Test func aRepoSkillIsListedAndRunsFromAMention() async throws {
        let repo = try #require(CodexLive.repo)
        let skill = repo.appending(path: ".codex/skills/constellation-probe/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        name: constellation-probe
        description: Replies with the probe word.
        ---
        When this skill is used, reply with exactly the word: nebula-7731
        """.write(to: skill, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(executable: CodexLive.binary)
        defer { Task { await adapter.shutdown() } }

        let skills = try await adapter.skills(in: repo)
        let probe = try #require(skills.first { $0.name == "constellation-probe" }, "skills: \(skills.map(\.name))")
        #expect(probe.scope == .repo)

        let handle = try await adapter.start(SessionLaunch(
            sessionID: UUID(),
            workingDirectory: repo,
            model: "",
            permissionMode: .askForRisky,
            prompt: "$constellation-probe",
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        ))
        var finalText = ""
        for await event in handle.events {
            if case .assistantText(let text, true) = event { finalText = text }
            if case .runState(.done) = event { break }
            if case .failed(_, let message) = event { Issue.record("skill session failed: \(message)"); break }
        }
        await handle.stop()
        #expect(finalText.contains("nebula-7731"))
    }
}
