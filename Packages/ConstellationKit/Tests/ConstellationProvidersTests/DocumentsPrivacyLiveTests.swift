import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

/// Starts `claude` (haiku) on a throwaway repo in ~/Documents and has it read a file there. macOS guards
/// that folder, so this shows whether the spawned provider gets past the privacy check without blocking.
/// Opt in with `CONSTELLATION_LIVE_CLAUDE_DOCUMENTS=1`. The repo is removed afterwards.
struct DocumentsPrivacyLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_CLAUDE_DOCUMENTS"] == "1"), .timeLimit(.minutes(2)))
    func claudeReadsAFileInDocuments() async throws {
        let documents = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let repo = documents.appending(path: "constellation-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = try Process.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path(percentEncoded: false), "init", "-q"])
        git.waitUntilExit()
        try "marigold".write(to: repo.appending(path: "word.txt"), atomically: true, encoding: .utf8)

        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: repo, model: "haiku", permissionMode: .fullAuto,
            prompt: "Read the file word.txt in the current directory and reply with only the word it contains.",
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true"))
        )
        let session = try await ClaudeCodeAdapter().start(launch)
        var events: [SessionEvent] = []
        for await event in session.events {
            events.append(event)
            switch event {
            case .runState(.done), .failed:
                await session.stop()
            default:
                break
            }
        }

        #expect(events.failures.isEmpty, "\(events.failures)")
        #expect(events.finalTexts.last?.lowercased().contains("marigold") == true, "\(events.finalTexts)")
    }
}
