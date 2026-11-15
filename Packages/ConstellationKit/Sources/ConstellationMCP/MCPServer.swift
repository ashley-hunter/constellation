import ConstellationCore
import Foundation

/// What `constellation-mcp` does with each tool call. The executable relays to the app over the bridge socket.
public protocol MCPToolBackend: Sendable {
    /// Waits for the app's answer: the value, or nil when you declined. Cancelling the task withdraws the request.
    func requestSecret(name: String, reason: String) async throws -> String?
    func reportOutcome(_ outcome: Outcome) async throws
}

/// The stdio side of the Constellation MCP server: newline-delimited JSON-RPC 2.0 speaking
/// `initialize`, `ping`, `tools/list` and `tools/call`. Requests run concurrently so a
/// `request_secret` waiting on you never blocks other calls.
public actor MCPServer {
    public static let name = "constellation"
    public static let version = "1.0.0"
    /// Newest first. Claude Code 2.1.314 asks for 2025-11-25 (after a `server/discover` probe, which we
    /// refuse so it falls back) and Codex 0.166 for 2025-06-18. Anything else gets the newest.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// Precedes the value in a `request_secret` result, so tool output shown to you can be cut here.
    public static let secretValueMarker = "Its value, for this call only, is: "

    public static let instructions = """
        Constellation is the app that launched this session and shows its progress to the user.
        - At the end of every turn that finishes a task, call report_outcome with status "succeeded" or \
        "failed" and a one-line summary of what happened. Report "failed" when you could not do what was asked.
        - When you need a secret such as an API key, token or password, call request_secret with the \
        environment variable name and why you need it. Never ask for secrets in chat, and never write a \
        secret's value into files, commits or messages.
        """

    private let backend: any MCPToolBackend
    private let write: @Sendable (Data) -> Void
    private var inflight: [JSONValue: Task<Void, Never>] = [:]

    public init(backend: any MCPToolBackend, write: @escaping @Sendable (Data) -> Void) {
        self.backend = backend
        self.write = write
    }

    /// Serves requests until `lines` ends, then gives calls in flight a moment to finish
    /// (a `report_outcome` sent just before the client hung up) and cancels the rest.
    public func run(lines: AsyncStream<Data>) async {
        for await line in lines where !line.isEmpty {
            receive(line)
        }
        let pending = Array(inflight.values)
        let deadline = Task {
            try await Task.sleep(for: .seconds(2))
            for task in pending { task.cancel() }
        }
        for task in pending { await task.value }
        deadline.cancel()
    }

    /// Handles one message and returns the response line, if it has one. Used directly by tests.
    public func response(to line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(Message.self, from: line) else {
            return encode(.failure(id: .null, .parseError))
        }
        // A message without a method is a response, and we never send requests.
        guard let method = message.method else { return nil }
        guard let id = message.id else {
            handleNotification(method, params: message.params)
            return nil
        }
        return encode(await respond(id: id, method: method, params: message.params))
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: line),
              let method = message.method, let id = message.id
        else {
            Task { if let response = await response(to: line) { emit(response) } }
            return
        }
        inflight[id] = Task {
            let response = await respond(id: id, method: method, params: message.params)
            guard !Task.isCancelled else { return }
            inflight[id] = nil
            if let data = encode(response) { emit(data) }
        }
    }

    private func emit(_ data: Data) {
        write(data + Data("\n".utf8))
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        guard method == "notifications/cancelled", let requestID = params?["requestId"] else { return }
        inflight.removeValue(forKey: requestID)?.cancel()
    }

    private func respond(id: JSONValue, method: String, params: JSONValue?) async -> Response {
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested)
                ? requested : Self.supportedProtocolVersions[0]
            return .success(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.name), "version": .string(Self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return .success(id: id, [:])
        case "tools/list":
            return .success(id: id, ["tools": .array(MCPTool.allCases.map(\.definition))])
        case "tools/call":
            guard let name = params?["name"]?.stringValue, let tool = MCPTool(rawValue: name) else {
                return .failure(id: id, .invalidParams("Unknown tool"))
            }
            return .success(id: id, await call(tool, arguments: params?["arguments"] ?? [:]).json)
        default:
            return .failure(id: id, .methodNotFound(method))
        }
    }

    private func call(_ tool: MCPTool, arguments: JSONValue) async -> ToolResult {
        do {
            switch tool {
            case .requestSecret:
                guard let name = arguments["name"]?.stringValue, name.isEnvironmentVariableName else {
                    return .error("name must be an environment variable name, such as STRIPE_API_KEY.")
                }
                let reason = arguments["reason"]?.stringValue ?? ""
                guard let value = try await backend.requestSecret(name: name, reason: reason) else {
                    return .error("The user declined to provide \(name). Do not ask for it in chat; continue without it or explain what is blocked.")
                }
                return .text("""
                    Secret provided and saved. It becomes the env var \(name) only after this session is resumed, \
                    so $\(name) is empty for now: pass the value explicitly to the commands that need it this turn, \
                    for example `\(name)=<value> command`, without writing it into files. \
                    \(Self.secretValueMarker)\(value)
                    """)
            case .reportOutcome:
                guard let status = arguments["status"]?.stringValue.flatMap(Outcome.Status.init(rawValue:)) else {
                    return .error("status must be \"succeeded\" or \"failed\".")
                }
                let summary = arguments["summary"]?.stringValue ?? ""
                try await backend.reportOutcome(Outcome(status: status, summary: summary))
                return .text("Outcome recorded.")
            }
        } catch {
            return .error("Constellation could not handle \(tool.rawValue): \(error)")
        }
    }

    private func encode(_ response: Response) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try? encoder.encode(response)
    }
}

enum MCPTool: String, CaseIterable {
    case requestSecret = "request_secret"
    case reportOutcome = "report_outcome"

    var definition: JSONValue {
        switch self {
        case .requestSecret:
            [
                "name": .string(rawValue),
                "title": "Request a secret",
                "description": """
                    Ask the user for a secret (API key, token, password) instead of asking in chat. \
                    Waits until the user answers. The value is returned for use this turn and becomes an environment variable after the session is resumed.
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Environment variable name, e.g. STRIPE_WEBHOOK_SECRET."],
                        "reason": ["type": "string", "description": "One sentence on why you need it."],
                    ],
                    "required": ["name", "reason"],
                    "additionalProperties": false,
                ],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ]
        case .reportOutcome:
            [
                "name": .string(rawValue),
                "title": "Report outcome",
                "description": "Report whether the task this turn worked on succeeded or failed, with a one-line summary. Call it at the end of every turn that finishes a task.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["succeeded", "failed"]],
                        "summary": ["type": "string", "description": "One line on what happened."],
                    ],
                    "required": ["status", "summary"],
                    "additionalProperties": false,
                ],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ]
        }
    }
}

private struct Message: Decodable {
    var id: JSONValue?
    var method: String?
    var params: JSONValue?
}

private enum Response: Encodable {
    case success(id: JSONValue, JSONValue)
    case failure(id: JSONValue, RPCError)

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case let .success(id, result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case let .failure(id, error):
            try container.encode(id, forKey: .id)
            try container.encode(["code": .int(error.code), "message": .string(error.message)] as JSONValue, forKey: .error)
        }
    }
}

private struct RPCError {
    var code: Int
    var message: String

    static let parseError = RPCError(code: -32700, message: "Parse error")
    static func methodNotFound(_ method: String) -> RPCError { RPCError(code: -32601, message: "Method not found: \(method)") }
    static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
}

private struct ToolResult {
    var text: String
    var isError: Bool

    static func text(_ text: String) -> ToolResult { ToolResult(text: text, isError: false) }
    static func error(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }

    var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

extension String {
    var isEnvironmentVariableName: Bool {
        guard let first = unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }
}
