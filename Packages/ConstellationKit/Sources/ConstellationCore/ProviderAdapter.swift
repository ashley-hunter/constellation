import Foundation

/// Launches sessions for one provider. Codex shares one app-server across its sessions,
/// so the adapter is per provider and each started session gets its own handle.
public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    func start(_ launch: SessionLaunch) async throws -> any ProviderSessionHandle
}

public protocol ProviderSessionHandle: Sendable {
    var sessionID: UUID { get }
    var events: AsyncStream<SessionEvent> { get }
    /// Starts a turn, or steers the running one: Codex calls `turn/steer`, Claude Code queues it itself.
    func send(_ message: UserMessage) async throws
    func answer(ask: Ask, with answer: AskAnswer) async throws
    func interrupt() async throws
    /// Closes the session's input, then terminates its process after a grace period.
    func stop() async
}

extension ProviderSessionHandle {
    public func send(userMessage: String) async throws {
        try await send(UserMessage(text: userMessage))
    }
}

public struct SessionLaunch: Hashable, Sendable {
    public var sessionID: UUID
    public var workingDirectory: URL
    public var model: String
    public var permissionMode: PermissionMode
    /// The first message, sent once the provider is up.
    public var message: UserMessage?
    public var environment: [String: String]
    public var mcpServer: MCPServerConfig
    /// The provider's native id to resume, or nil for a new session.
    public var resumeID: String?
    public var effort: String?
    public var fastMode = false
    /// With `resumeID`: where to cut the resumed conversation, for Rewind and Fork.
    public var cut: ConversationCut?
    /// Added to the agent's own instructions, out of the transcript: Claude Code's appended system
    /// prompt, Codex's developer instructions.
    public var instructions: String?

    public init(
        sessionID: UUID,
        workingDirectory: URL,
        model: String,
        permissionMode: PermissionMode,
        prompt: String?,
        environment: [String: String] = [:],
        mcpServer: MCPServerConfig,
        resumeID: String? = nil
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.message = prompt.map { UserMessage(text: $0) }
        self.environment = environment
        self.mcpServer = mcpServer
        self.resumeID = resumeID
    }
}

/// How a provider launches the Constellation MCP server for a session.
public struct MCPServerConfig: Hashable, Codable, Sendable {
    public static let serverName = "constellation"

    public var command: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(command: URL, arguments: [String] = [], environment: [String: String] = [:]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}
