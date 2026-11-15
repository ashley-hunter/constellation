import ConstellationCore
import Foundation

// Hand-written wire types for the parts of the `codex app-server` v2 protocol Constellation uses,
// checked against `codex app-server generate-json-schema --experimental` from codex-cli 0.166.0.
// Decoding is lenient: unknown fields are ignored and unknown enum values fall through.

enum CodexMethod {
    static let initialize = "initialize"
    static let initialized = "initialized"
    static let threadStart = "thread/start"
    static let threadResume = "thread/resume"
    static let threadUnsubscribe = "thread/unsubscribe"
    static let turnStart = "turn/start"
    static let turnSteer = "turn/steer"
    static let turnInterrupt = "turn/interrupt"
    static let threadFork = "thread/fork"
    static let threadRevert = "thread/revert"
    static let modelList = "model/list"
    static let skillsList = "skills/list"
    static let accountRead = "account/read"

    static let threadStatusChanged = "thread/status/changed"
    static let turnStarted = "turn/started"
    static let turnCompleted = "turn/completed"
    static let itemStarted = "item/started"
    static let itemCompleted = "item/completed"
    static let agentMessageDelta = "item/agentMessage/delta"
    static let tokenUsageUpdated = "thread/tokenUsage/updated"
    static let serverRequestResolved = "serverRequest/resolved"
    static let error = "error"

    static let commandApproval = "item/commandExecution/requestApproval"
    static let fileChangeApproval = "item/fileChange/requestApproval"
    static let permissionsApproval = "item/permissions/requestApproval"
    static let requestUserInput = "item/tool/requestUserInput"
}

// MARK: Client requests

struct CodexInitializeParams: Encodable {
    struct ClientInfo: Encodable {
        var name: String
        var title: String
        var version: String
    }

    struct Capabilities: Encodable {
        var experimentalApi: Bool
    }

    var clientInfo: ClientInfo
    var capabilities: Capabilities
}

/// The `config` overrides passed to `thread/start` and `thread/resume`.
struct CodexThreadConfig: Encodable, Hashable {
    struct MCPServer: Encodable, Hashable {
        var command: String
        var args: [String]
        var env: [String: String]
    }

    struct ShellEnvironmentPolicy: Encodable, Hashable {
        var set: [String: String]
    }

    var mcpServers: [String: MCPServer]
    var shellEnvironmentPolicy: ShellEnvironmentPolicy?
    var developerInstructions: String?

    enum CodingKeys: String, CodingKey {
        case mcpServers = "mcp_servers"
        case shellEnvironmentPolicy = "shell_environment_policy"
        case developerInstructions = "developer_instructions"
    }
}

struct CodexThreadStartParams: Encodable {
    var cwd: String
    var model: String?
    var approvalPolicy: String
    var sandbox: String
    var config: CodexThreadConfig
}

struct CodexThreadResumeParams: Encodable {
    var threadId: String
    var cwd: String
    var model: String?
    var approvalPolicy: String
    var sandbox: String
    var config: CodexThreadConfig
    var excludeTurns = true
}

/// `thread/fork`: a new thread with the source's turns through `lastTurnId` (all when nil).
struct CodexThreadForkParams: Encodable {
    var threadId: String
    var lastTurnId: String?
    var cwd: String
    var model: String?
    var approvalPolicy: String
    var sandbox: String
    var config: CodexThreadConfig
    var excludeTurns = true
}

/// `thread/revert`: drops `beforeTurnId` and every later turn from the thread's history. Files are
/// left alone.
struct CodexThreadRevertParams: Encodable {
    var threadId: String
    var beforeTurnId: String
}

struct CodexModelListResponse: Decodable {
    struct Model: Decodable {
        struct Effort: Decodable {
            var reasoningEffort: String
        }

        struct ServiceTier: Decodable {
            var id: String
        }

        var id: String
        var model: String
        var displayName: String
        var hidden: Bool
        var isDefault: Bool
        var defaultReasoningEffort: String?
        var supportedReasoningEfforts: [Effort]
        var serviceTiers: [ServiceTier]?
    }

    var data: [Model]
    var nextCursor: String?
}

struct CodexModelListParams: Encodable {
    var cursor: String?
}

struct CodexThreadResponse: Decodable {
    struct Thread: Decodable {
        var id: String
    }

    var thread: Thread
    var model: String?
}

/// A `UserInput` item. Images go as `localImage`, which the app-server reads from disk.
enum CodexUserInput: Encodable, Hashable {
    case text(String)
    case localImage(path: String)
    case skill(name: String, path: String)

    private enum CodingKeys: String, CodingKey { case type, text, path, name }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }

    /// Images first, then the text with the paths of everything else, then a skill item for each
    /// `$name` in the text that names one of `skills`.
    static func items(for message: UserMessage, skills: [SlashCommand] = []) -> [CodexUserInput] {
        let images = message.inlineAttachments(for: .codex).map { CodexUserInput.localImage(path: $0.storedURL.path(percentEncoded: false)) }
        let text = message.promptText(for: .codex)
        let mentioned = SlashCommand.codexSkillMentions(in: message.text).compactMap { name in
            skills.first { $0.name == name }.flatMap { skill in skill.path.map { CodexUserInput.skill(name: name, path: $0) } }
        }
        return images + (text.allSatisfy(\.isWhitespace) ? [] : [.text(text)]) + mentioned
    }
}

struct CodexSkillsListParams: Encodable {
    var cwds: [String]
}

struct CodexSkillsListResponse: Decodable {
    struct Entry: Decodable {
        var cwd: String
        var skills: [Skill]
    }

    struct Skill: Decodable {
        struct Interface: Decodable {
            var displayName: String?
            var shortDescription: String?
        }

        var name: String
        var description: String
        var shortDescription: String?
        var interface: Interface?
        var path: String
        var scope: String
        var enabled: Bool
    }

    var data: [Entry]

    /// Enabled skills for `cwd`, as `/` menu entries. Repo skills first, and each name once.
    func commands(for cwd: String) -> [SlashCommand] {
        let skills = data.first { $0.cwd == cwd }?.skills ?? data.flatMap(\.skills)
        let order: [SlashCommand.Scope] = [.repo, .user, .system]
        var seen: Set<String> = []
        return skills.filter(\.enabled).map { skill in
            SlashCommand(
                name: skill.name,
                description: skill.shortDescription ?? skill.interface?.shortDescription ?? skill.description,
                kind: .skill,
                scope: SlashCommand.Scope(rawValue: skill.scope) ?? .system,
                path: skill.path
            )
        }
        .enumerated()
        .sorted { (order.firstIndex(of: $0.element.scope) ?? 3, $0.offset) < (order.firstIndex(of: $1.element.scope) ?? 3, $1.offset) }
        .map(\.element)
        .filter { seen.insert($0.name).inserted }
    }
}

struct CodexCollaborationMode: Encodable, Hashable {

    struct Settings: Encodable, Hashable {
        var model: String
        var reasoningEffort: String?
        var developerInstructions: String?

        enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
            case developerInstructions = "developer_instructions"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
            // null asks Codex for the built-in instructions of the selected mode.
            try container.encode(developerInstructions, forKey: .developerInstructions)
        }
    }

    var mode = "default"
    var settings: Settings
}

/// Model, effort, service tier and policies apply to this turn and the ones after it.
struct CodexTurnStartParams: Encodable {
    var threadId: String
    var input: [CodexUserInput]
    var collaborationMode: CodexCollaborationMode?
    var model: String?
    var effort: String?
    var serviceTier: String?
    var approvalPolicy: String?
    var sandboxPolicy: CodexSandboxPolicy?
}

/// The turn-level sandbox, the object form of `thread/start`'s `sandbox` string.
struct CodexSandboxPolicy: Encodable, Hashable {
    var type: String

    init(sandbox: String) {
        type = switch sandbox {
        case "read-only": "readOnly"
        case "workspace-write": "workspaceWrite"
        default: "dangerFullAccess"
        }
    }
}

struct CodexTurnSteerParams: Encodable {
    var threadId: String
    var expectedTurnId: String
    var input: [CodexUserInput]
}

struct CodexTurnInterruptParams: Encodable {
    var threadId: String
    var turnId: String
}

struct CodexThreadIDParams: Encodable {
    var threadId: String
}

struct CodexTurnResponse: Decodable {
    var turn: CodexTurn
}

// MARK: Notifications

struct CodexTurn: Decodable {
    struct TurnError: Decodable {
        var message: String
        var codexErrorInfo: CodexJSON?
    }

    var id: String
    var status: String
    var error: TurnError?
}

struct CodexThreadStatus: Decodable {
    var type: String
    var activeFlags: [String]?
}

struct CodexThreadStatusChanged: Decodable {
    var threadId: String
    var status: CodexThreadStatus
}

struct CodexTurnNotification: Decodable {
    var threadId: String
    var turn: CodexTurn
}

struct CodexItemNotification: Decodable {
    var threadId: String
    var turnId: String
    var item: CodexItem
}

struct CodexAgentMessageDelta: Decodable {
    var threadId: String
    var itemId: String
    var delta: String
}

struct CodexTokenUsageUpdated: Decodable {
    struct Usage: Decodable {
        struct Breakdown: Decodable {
            var inputTokens: Int
            var outputTokens: Int
            var cachedInputTokens: Int
            var totalTokens: Int?
        }

        var total: Breakdown
        /// The latest model call alone. These add up to `total`, and unlike it they don't restart
        /// or repeat when a thread is resumed in a new process.
        var last: Breakdown?
        var modelContextWindow: Int?
    }

    var threadId: String
    var tokenUsage: Usage
}

struct CodexServerRequestResolved: Decodable {
    var threadId: String
    var requestId: CodexRequestID
}

struct CodexErrorNotification: Decodable {
    var threadId: String
    var error: CodexTurn.TurnError
    var willRetry: Bool
}

/// The `ThreadItem` variants Constellation shows. Everything else decodes as `.other`.
enum CodexItem: Decodable {
    struct CommandAction: Decodable {
        var command: String
    }

    struct FileChange: Decodable {
        var path: String
        var diff: String
    }

    case userMessage(id: String, text: String)
    case agentMessage(id: String, text: String)
    case commandExecution(id: String, command: String, actions: [CommandAction], status: String, exitCode: Int?, output: String?)
    case fileChange(id: String, changes: [FileChange], status: String)
    case mcpToolCall(id: String, server: String, tool: String, status: String)
    case webSearch(id: String, query: String)
    case other(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, text, content, command, commandActions, status, exitCode, aggregatedOutput
        case changes, server, tool, query
    }

    private struct UserContent: Decodable {
        var type: String
        var text: String?
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func id() throws -> String { try c.decode(String.self, forKey: .id) }
        func string(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        switch type {
        case "userMessage":
            let content = try c.decodeIfPresent([UserContent].self, forKey: .content) ?? []
            self = .userMessage(id: try id(), text: content.compactMap(\.text).joined(separator: "\n"))
        case "agentMessage":
            self = .agentMessage(id: try id(), text: try string(.text))
        case "commandExecution":
            self = .commandExecution(
                id: try id(),
                command: try string(.command),
                actions: try c.decodeIfPresent([CommandAction].self, forKey: .commandActions) ?? [],
                status: try string(.status),
                exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode),
                output: try c.decodeIfPresent(String.self, forKey: .aggregatedOutput)
            )
        case "fileChange":
            self = .fileChange(
                id: try id(),
                changes: try c.decodeIfPresent([FileChange].self, forKey: .changes) ?? [],
                status: try string(.status)
            )
        case "mcpToolCall":
            self = .mcpToolCall(id: try id(), server: try string(.server), tool: try string(.tool), status: try string(.status))
        case "webSearch":
            self = .webSearch(id: try id(), query: try string(.query))
        default:
            self = .other(type: type)
        }
    }
}

// MARK: Server requests

struct CodexCommandApprovalParams: Decodable {
    var threadId: String
    var itemId: String
    var startedAtMs: Int64?
    var command: String?
    var cwd: String?
    var reason: String?
    var commandActions: [CodexItem.CommandAction]?
    var proposedExecpolicyAmendment: [String]?
    /// Each entry is a decision string or a single-key object such as `acceptWithExecpolicyAmendment`.
    var availableDecisions: [CodexJSON]?
}

struct CodexFileChangeApprovalParams: Decodable {
    var threadId: String
    var itemId: String
    var startedAtMs: Int64?
    var reason: String?
    var grantRoot: String?
}

struct CodexPermissionsApprovalParams: Decodable {
    var threadId: String
    var itemId: String
    var startedAtMs: Int64?
    var cwd: String?
    var reason: String?
    var permissions: CodexJSON
}

struct CodexUserInputParams: Decodable {
    struct Question: Decodable {
        struct Option: Decodable {
            var label: String
            var description: String?
        }

        var id: String
        var header: String
        var question: String
        var isOther: Bool?
        var isSecret: Bool?
        var options: [Option]?
    }

    var threadId: String
    var itemId: String
    var questions: [Question]
}

struct CodexUserInputResponse: Encodable {
    struct Answer: Encodable {
        var answers: [String]
    }

    var answers: [String: Answer]
}

struct CodexDecisionResponse: Encodable {
    var decision: CodexJSON
}

struct CodexPermissionsResponse: Encodable {
    var permissions: CodexJSON
    var scope: String
}
