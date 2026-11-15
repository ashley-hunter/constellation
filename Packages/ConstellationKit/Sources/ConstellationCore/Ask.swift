import Foundation

/// A request from a session that blocks it until answered.
public struct Ask: Identifiable, Hashable, Codable, Sendable {
    /// The provider's own request id, unique within its session.
    public var id: String
    public var sessionID: UUID
    public var kind: AskKind
    public var createdAt: Date
    public var status: AskStatus

    public init(id: String, sessionID: UUID, kind: AskKind, createdAt: Date = .now, status: AskStatus = .pending) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.createdAt = createdAt
        self.status = status
    }
}

public enum AskStatus: String, Hashable, Codable, Sendable {
    case pending, answered, expired, cancelled
}

public enum AskKind: Hashable, Codable, Sendable {
    case permission(PermissionAsk)
    case question(QuestionAsk)
    case secret(SecretAsk)
}

public struct PermissionAsk: Hashable, Codable, Sendable {
    public var toolName: String
    /// The literal command for shell tools, otherwise a short description.
    public var summary: String
    /// The diff for file edits, or the raw input otherwise.
    public var inputPreview: String?
    public var offeredDecisions: [PermissionDecision]

    public init(
        toolName: String,
        summary: String,
        inputPreview: String? = nil,
        offeredDecisions: [PermissionDecision] = PermissionDecision.allCases
    ) {
        self.toolName = toolName
        self.summary = summary
        self.inputPreview = inputPreview
        self.offeredDecisions = offeredDecisions
    }
}

public enum PermissionDecision: String, CaseIterable, Hashable, Codable, Sendable {
    case allowOnce
    case deny
    case allowForSession
    case allowAlwaysInProject
}

public struct QuestionAsk: Hashable, Codable, Sendable {
    /// One to four questions.
    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    public struct Question: Identifiable, Hashable, Codable, Sendable {
        public var id: String
        public var header: String
        public var prompt: String
        public var options: [Option]
        public var multiSelect: Bool

        public init(id: String, header: String, prompt: String, options: [Option], multiSelect: Bool = false) {
            self.id = id
            self.header = header
            self.prompt = prompt
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public struct Option: Hashable, Codable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }
}

public struct SecretAsk: Hashable, Codable, Sendable {
    /// The environment variable name, e.g. `STRIPE_WEBHOOK_SECRET`.
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// An answer to an ask. Deliberately not Codable: secret values are never persisted outside the Keychain.
public enum AskAnswer: Hashable, Sendable {
    case permission(PermissionDecision)
    /// Selected option labels, or free text, keyed by question id.
    case questions([String: [String]])
    case secret(value: String, saveForProject: Bool)
    case secretDeclined
    /// Deny (Claude Code) or decline and steer (Codex) with a message.
    case reply(String)
}
