import Foundation

// How each provider is told to launch the Constellation MCP server. These live in Core because the
// provider adapters render them and depend only on Core.
extension MCPServerConfig {
    /// Tool names as Claude Code sees them, for `--allowedTools` so they never raise a Permission ask.
    public static let claudeAllowedTools = ["request_secret", "report_outcome"].map { "mcp__\(serverName)__\($0)" }

    /// The value for `claude --mcp-config`, which takes inline JSON as well as a path.
    public func claudeMCPConfigJSON() -> String {
        struct Server: Encodable {
            var type = "stdio"
            var command: String
            var args: [String]
            var env: [String: String]
        }
        let config = ["mcpServers": [Self.serverName: Server(command: command.path(percentEncoded: false), args: arguments, env: environment)]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(config), as: UTF8.self)
    }

    /// The `config` entry for Codex's `thread/start`, which applies dotted keys like `codex -c`.
    public var codexConfigKey: String { "mcp_servers.\(Self.serverName)" }

    public var codexServer: CodexMCPServer {
        CodexMCPServer(command: command.path(percentEncoded: false), args: arguments, env: environment)
    }
}

/// One `[mcp_servers.<name>]` table in Codex's config.
public struct CodexMCPServer: Hashable, Codable, Sendable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var startupTimeoutSec: Int = 20
    /// `request_secret` waits for you, so the 60s default is far too short.
    public var toolTimeoutSec: Int = 7 * 24 * 60 * 60
    /// Our tools never raise a Permission ask.
    public var defaultToolsApprovalMode = "approve"

    enum CodingKeys: String, CodingKey {
        case command, args, env
        case startupTimeoutSec = "startup_timeout_sec"
        case toolTimeoutSec = "tool_timeout_sec"
        case defaultToolsApprovalMode = "default_tools_approval_mode"
    }
}
