import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// Drives the installed `claude` in a throwaway git repo. Opt in with `CONSTELLATION_LIVE_CLAUDE=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CLAUDE"] == "1"))
struct ClaudeCodeLiveTests {
    @Test(.timeLimit(.minutes(3)))
    func permissionAnswerAndFollowUpTurn() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "constellation-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = try Process.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path(percentEncoded: false), "init", "-q"])
        git.waitUntilExit()

        let launch = SessionLaunch(
            sessionID: UUID(),
            workingDirectory: repo,
            model: "haiku",
            permissionMode: .askForEverything,
            prompt: "Use the Bash tool to run exactly: touch live.txt . Then say done.",
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        )
        let session = try await ClaudeCodeAdapter().start(launch)

        var events: [SessionEvent] = []
        var turnsDone = 0
        for await event in session.events {
            events.append(event)
            switch event {
            case .askRaised(let ask):
                try await session.answer(ask: ask, with: .permission(.allowOnce))
            case .runState(.done):
                turnsDone += 1
                if turnsDone == 1 {
                    try await session.send(userMessage: "Reply with exactly: ok")
                } else {
                    await session.stop()
                }
            case .failed:
                await session.stop()
            default:
                break
            }
        }

        #expect(events.failures.isEmpty, "\(events.failures)")
        #expect(events.asks.count == 1)
        #expect(events.toolCalls.contains { $0.summary == "touch live.txt" })
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: "live.txt").path(percentEncoded: false)))
        #expect(events.finalTexts.last?.lowercased().contains("ok") == true)
        #expect(events.last == .exited(code: 0))
    }

    /// The Constellation MCP tools are pre-allowed, so calling one raises no ask even when everything asks.
    /// No bridge is listening, so the helper answers with an error; the call itself is what's checked.
    @Test(.timeLimit(.minutes(3)))
    func constellationToolsNeedNoPermission() async throws {
        let helper = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug/constellation-mcp").standardized
        try #require(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)), "build constellation-mcp first")
        let repo = FileManager.default.temporaryDirectory.appending(path: "constellation-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let launch = SessionLaunch(
            sessionID: UUID(),
            workingDirectory: repo,
            model: "haiku",
            permissionMode: .askForEverything,
            prompt: "Call the report_outcome tool once with status succeeded and summary smoke. Then say done.",
            mcpServer: MCPServerConfig(command: helper, environment: ["CONSTELLATION_MCP_SOCKET": repo.appending(path: "none.sock").path()])
        )
        let session = try await ClaudeCodeAdapter().start(launch)

        var events: [SessionEvent] = []
        for await event in session.events {
            events.append(event)
            switch event {
            case .askRaised(let ask):
                try await session.answer(ask: ask, with: .permission(.deny))
            case .runState(.done), .failed:
                await session.stop()
            default:
                break
            }
        }
        #expect(events.asks.isEmpty, "\(events.asks)")
        #expect(events.toolCalls.contains { $0.name == "mcp__constellation__report_outcome" }, "\(events.toolCalls)")
        #expect(events.failures.isEmpty, "\(events.failures)")
    }

    @Test(.timeLimit(.minutes(3)))
    func interruptWhileBlocked() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "constellation-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let launch = SessionLaunch(
            sessionID: UUID(),
            workingDirectory: repo,
            model: "haiku",
            permissionMode: .askForEverything,
            prompt: "Use the Bash tool to run exactly: touch never.txt . Then say done.",
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        )
        let session = try await ClaudeCodeAdapter().start(launch)

        var events: [SessionEvent] = []
        for await event in session.events {
            events.append(event)
            if case .askRaised = event { try await session.interrupt() }
            if event == .interrupted { await session.stop() }
        }
        let ask = try #require(events.asks.first)
        #expect(events.contains(.askWithdrawn(askID: ask.id)))
        #expect(events.failures.isEmpty)
    }
}
