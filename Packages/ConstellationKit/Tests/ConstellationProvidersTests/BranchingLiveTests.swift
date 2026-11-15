import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// Against the real providers: switch the model before a turn, then fork from the first message and
/// rewind to the second. Opt in as for `ClaudeCodeLiveTests` and `CodexLiveTests`. Everything runs
/// in a throwaway repo with short prompts (haiku for Claude Code).
struct BranchingLiveTests {
    static let remember = ["Remember the word apple. Reply with only: ok", "Remember the word pear too. Reply with only: ok"]
    static let recall = UserMessage(text: "Which words did I ask you to remember? Reply with only the words, lowercase.")

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(5)))
    func claudeSwitchesModelForksAndRewinds() async throws {
        let repo = try BranchingRepo()
        defer { repo.remove() }
        let adapter = ClaudeCodeAdapter()
        // Launched on sonnet but switched to haiku before the first message, so every turn runs on haiku.
        let session = try #require(try await adapter.start(repo.launch(model: "sonnet")) as? ClaudeCodeSession)
        await session.adjust(TurnSettings(model: "haiku", effort: "low", permissionMode: .fullAuto))
        let events = try await Self.converse(session, Self.remember.map { UserMessage(text: $0) })
        #expect(await session.appliedSettings.model == "haiku")
        #expect(await session.appliedSettings.effort == "low")
        let nativeID = try #require(events.compactMap { if case .started(let id) = $0 { id } else { nil } }.last)
        let transcript = Transcript(events)

        var fork = repo.launch(model: "haiku", resumeID: nativeID)
        fork.cut = transcript.forkCut(atMessage: 0, provider: .claudeCode)
        #expect(fork.cut != nil && fork.cut != .fork(through: nil))
        let forked = try await Self.converse(try await adapter.start(fork), [Self.recall])
        #expect(forked.contains { if case .started(let id) = $0 { id != nativeID } else { false } })
        Self.expectOnlyApple(forked)

        var rewind = repo.launch(model: "haiku", resumeID: nativeID)
        rewind.cut = transcript.rewindCut(toMessage: 1, provider: .claudeCode)
        Self.expectOnlyApple(try await Self.converse(try await adapter.start(rewind), [Self.recall]))
    }

    @Test(.enabled(if: CodexLive.binary != nil), .timeLimit(.minutes(6)))
    func codexSwitchesModelForksAndRewinds() async throws {
        let repo = try BranchingRepo()
        defer { repo.remove() }
        let adapter = CodexAdapter(executable: CodexLive.binary)
        defer { Task { await adapter.shutdown() } }
        let models = try await adapter.models()
        #expect(models.first?.id == "")
        let other = try #require(models.dropFirst().last)

        let session = try #require(try await adapter.start(repo.launch(model: "")) as? CodexSessionHandle)
        await session.adjust(TurnSettings(model: other.id, effort: other.efforts.first, fastMode: other.supportsFastMode, permissionMode: .fullAuto))
        let events = try await Self.converse(session, Self.remember.map { UserMessage(text: $0) })
        let threadID = session.threadID
        let transcript = Transcript(events)

        var fork = repo.launch(model: other.id, resumeID: threadID)
        fork.cut = transcript.forkCut(atMessage: 0, provider: .codex)
        let forked = try await Self.converse(try await adapter.start(fork), [Self.recall])
        #expect(forked.contains { if case .started(let id) = $0 { id != threadID } else { false } })
        Self.expectOnlyApple(forked)

        var rewind = repo.launch(model: other.id, resumeID: threadID)
        rewind.cut = transcript.rewindCut(toMessage: 1, provider: .codex)
        #expect(rewind.cut != nil)
        Self.expectOnlyApple(try await Self.converse(try await adapter.start(rewind), [Self.recall]))
    }

    /// Sends each message once the previous turn is done, then stops. Returns every event.
    static func converse(_ handle: any ProviderSessionHandle, _ messages: [UserMessage]) async throws -> [SessionEvent] {
        var pending = messages
        var events: [SessionEvent] = []
        try await handle.send(pending.removeFirst())
        for await event in handle.events {
            events.append(event)
            switch event {
            case .runState(.done):
                if pending.isEmpty {
                    await handle.stop()
                } else {
                    try await handle.send(pending.removeFirst())
                }
            case .failed(_, let message):
                Issue.record("turn failed: \(message)")
                await handle.stop()
            case .askRaised(let ask):
                Issue.record("unexpected ask: \(ask.kind.headline)")
                await handle.stop()
            default:
                break
            }
        }
        return events
    }

    static func expectOnlyApple(_ events: [SessionEvent]) {
        let last = events.compactMap { if case .assistantText(let text, isFinal: true) = $0 { text } else { nil } }.last ?? ""
        #expect(last.lowercased().contains("apple"), "\(last)")
        #expect(!last.lowercased().contains("pear"), "\(last)")
    }
}

private struct BranchingRepo {
    let root = FileManager.default.temporaryDirectory.appending(path: "constellation-branching-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = try Process.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", root.path(percentEncoded: false), "init", "-q"])
        git.waitUntilExit()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func launch(model: String, resumeID: String? = nil) -> SessionLaunch {
        SessionLaunch(
            sessionID: UUID(), workingDirectory: root, model: model, permissionMode: .fullAuto, prompt: nil,
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true")), resumeID: resumeID
        )
    }
}
