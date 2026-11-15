import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// Runs against the real `codex app-server`. Only enabled when both variables are set, and the repo
/// must be a throwaway: `CONSTELLATION_LIVE_CODEX=/path/to/codex CONSTELLATION_LIVE_CODEX_REPO=$(mktemp -d)/repo`.
@Suite(.enabled(if: CodexLive.binary != nil && CodexLive.repo != nil), .timeLimit(.minutes(5)))
struct CodexLiveTests {
    @Test func twoSessionsShareOneServerAndAnswerAsks() async throws {
        let adapter = CodexAdapter(executable: CodexLive.binary)
        defer { Task { await adapter.shutdown() } }

        func launch(_ prompt: String, _ mode: PermissionMode) -> SessionLaunch {
            SessionLaunch(
                sessionID: UUID(),
                workingDirectory: CodexLive.repo!,
                model: "",
                permissionMode: mode,
                prompt: prompt,
                environment: ["CONSTELLATION_LIVE_PROBE": "probe-4417"],
                mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
            )
        }

        async let denied = adapter.start(launch("Run the shell command `touch denied.txt` (not apply_patch), then reply done.", .askForEverything))
        async let probed = adapter.start(launch("Run the shell command `printenv CONSTELLATION_LIVE_PROBE` and reply with its output only.", .fullAuto))
        let (deniedHandle, probedHandle) = try await (denied, probed)

        var deniedEvents = deniedHandle.events.makeAsyncIterator()
        var askSeen = false
        while let event = await deniedEvents.next() {
            if case .askRaised(let ask) = event {
                askSeen = true
                try await deniedHandle.answer(ask: ask, with: .permission(.deny))
            }
            if case .runState(.done) = event { break }
            if case .failed(_, let message) = event { Issue.record("denied session failed: \(message)"); break }
        }
        #expect(askSeen)
        #expect(!FileManager.default.fileExists(atPath: CodexLive.repo!.appending(path: "denied.txt").path))

        var finalText = ""
        var probedEvents = probedHandle.events.makeAsyncIterator()
        while let event = await probedEvents.next() {
            if case .assistantText(let text, true) = event { finalText = text }
            if case .runState(.done) = event { break }
            if case .failed(_, let message) = event { Issue.record("probe session failed: \(message)"); break }
        }
        #expect(finalText.contains("probe-4417"))
    }

    /// Uses the adapter's own BinaryLocator lookup, the way the app does.
    @Test func approvedCommandRunsAndTheTurnFinishes() async throws {
        let adapter = CodexAdapter()
        defer { Task { await adapter.shutdown() } }
        let handle = try await adapter.start(SessionLaunch(
            sessionID: UUID(),
            workingDirectory: CodexLive.repo!,
            model: "",
            permissionMode: .askForEverything,
            prompt: "Run the shell command `touch approved.txt` (not apply_patch), then reply done.",
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        ))

        var asks = 0
        var finished = false
        for await event in handle.events {
            if case .askRaised(let ask) = event {
                asks += 1
                try await handle.answer(ask: ask, with: .permission(.allowOnce))
            }
            if case .runState(.done) = event { finished = true; break }
            if case .failed(_, let message) = event { Issue.record("session failed: \(message)"); break }
        }
        await handle.stop()
        #expect(asks >= 1)
        #expect(finished)
        #expect(FileManager.default.fileExists(atPath: CodexLive.repo!.appending(path: "approved.txt").path))
    }
}

enum CodexLive {
    static let binary = ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CODEX"].map { URL(filePath: $0) }
    static let repo = ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CODEX_REPO"].map { URL(filePath: $0) }
}
