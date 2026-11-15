import ConstellationCore
import ConstellationGit
import ConstellationGitHub
import ConstellationMCP
import ConstellationProcess
import ConstellationProviders
import ConstellationStore
import Foundation
import os

/// The package services the app model drives. Built once at launch.
struct AppServices: Sendable {
    let claudeCode: ClaudeCodeAdapter
    let codex: CodexAdapter
    let git: GitService
    let bridge: MCPBridge
    let secrets: SecretStore
    let store: Store
    let attachments: AttachmentLibrary
    let recorder: EventRecorder
    let pullRequests: PullRequestPoller
    /// `Contents/Helpers/constellation-mcp`, which providers launch as the Constellation MCP server.
    /// It is also the child watchdog.
    let mcpHelper: URL
    /// Pid files for running children, next to the store so a development run never sweeps the real app's.
    let childrenDirectory: URL
    /// Set when the database could not be opened and the app runs on an in-memory store.
    let storeError: String?

    func adapter(for provider: Provider) -> any ProviderAdapter {
        switch provider {
        case .claudeCode: claudeCode
        case .codex: codex
        }
    }

    static func live() -> AppServices {
        let store: Store
        var storeError: String?
        // `-ConstellationStorePath <file>` keeps development runs out of the real database.
        let override = UserDefaults.standard.string(forKey: "ConstellationStorePath").map { URL(filePath: $0) }
        do {
            store = try Store(url: override ?? Store.defaultURL)
        } catch {
            Log.app.error("Store failed to open: \(error, privacy: .public)")
            storeError = "Couldn't open the database, so nothing will be saved: \(error.localizedDescription)"
            store = try! Store.inMemory()
        }
        return AppServices(
            claudeCode: ClaudeCodeAdapter(),
            codex: CodexAdapter(),
            git: GitService(worktreesRoot: AppSettings.worktreeRoot(in: store)),
            bridge: MCPBridge(),
            secrets: SecretStore(),
            store: store,
            attachments: AttachmentLibrary(directory: override.map { URL(filePath: $0.path(percentEncoded: false) + "-attachments") } ?? AttachmentLibrary.defaultDirectory),
            recorder: EventRecorder(store: store),
            pullRequests: PullRequestPoller(),
            mcpHelper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/constellation-mcp"),
            childrenDirectory: override.map { URL(filePath: $0.path(percentEncoded: false) + "-children") } ?? ChildRegistry.defaultDirectory,
            storeError: storeError
        )
    }
}

enum Log {
    static let app = Logger(subsystem: "dev.ashleyhunter.constellation", category: "app")
    static let window = Logger(subsystem: "dev.ashleyhunter.constellation", category: "window")
    static let session = Logger(subsystem: "dev.ashleyhunter.constellation", category: "session")
}
