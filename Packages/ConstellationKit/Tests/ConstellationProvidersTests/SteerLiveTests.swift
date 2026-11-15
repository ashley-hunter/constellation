import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// Sends a message while a slow turn runs, the way ⌘↵ does, and checks the agent follows it. Opt
/// in as for `ClaudeCodeLiveTests` and `CodexLiveTests`.
struct SteerLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(3)))
    func claudeFollowsAMidTurnMessage() async throws {
        let repo = try LiveRepo()
        defer { repo.remove() }
        var launch = repo.launch(model: "haiku")
        launch.message = UserMessage(text: Self.slowPrompt)
        let handle = try await ClaudeCodeAdapter().start(launch)
        let result = await Self.steer(handle)
        #expect(result.steered)
        #expect(result.finalText.contains("STEERED"), "\(result.finalText)")
    }

    @Test(.enabled(if: CodexLive.binary != nil), .timeLimit(.minutes(5)))
    func codexSteersTheRunningTurn() async throws {
        let repo = try LiveRepo()
        defer { repo.remove() }
        let adapter = CodexAdapter(executable: CodexLive.binary)
        defer { Task { await adapter.shutdown() } }
        var launch = repo.launch(model: "")
        launch.message = UserMessage(text: Self.slowPrompt)
        let handle = try await adapter.start(launch)
        let result = await Self.steer(handle)
        #expect(result.steered)
        #expect(result.finalText.contains("STEERED"), "\(result.finalText)")
        #expect(result.checkpointsAfterSteer == 0, "a steer joins the running turn rather than starting one")
    }

    static let slowPrompt = "Count slowly to 20, running the shell command `sleep 1` between each number and saying each number as you go."
    static let steer = UserMessage(text: "Stop counting now and reply with only the word STEERED.")

    struct Result {
        var steered = false
        var finalText = ""
        var checkpointsAfterSteer = 0
    }

    /// Steers once the turn has visibly started, then waits for a finished turn whose answer
    /// follows the steer. Gives up after two minutes.
    static func steer(_ handle: any ProviderSessionHandle) async -> Result {
        var result = Result()
        var started = false
        let deadline = Task {
            try await Task.sleep(for: .seconds(120))
            await handle.stop()
        }
        defer { deadline.cancel() }
        for await event in handle.events {
            switch event {
            case .started:
                started = true
            case .assistantText, .toolCall:
                if case .assistantText(let text, isFinal: true) = event { result.finalText = text }
                guard started, !result.steered else { continue }
                result.steered = true
                do {
                    try await handle.send(steer)
                } catch {
                    Issue.record("steer failed: \(error)")
                    await handle.stop()
                }
            case .checkpoint:
                if result.steered { result.checkpointsAfterSteer += 1 }
            case .runState(.done):
                if result.steered, result.finalText.contains("STEERED") { await handle.stop() }
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
        return result
    }
}
