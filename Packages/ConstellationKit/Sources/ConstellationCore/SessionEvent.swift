import Foundation

/// A provider-neutral event, normalized from Claude Code or Codex protocol frames.
public enum SessionEvent: Hashable, Codable, Sendable {
    case started(nativeID: String)

    /// A message you sent, in your words, with what you attached. Recorded so transcripts and
    /// search include both sides. Optional so events stored before attachments still decode.
    case userMessage(String, attachments: [Attachment]? = nil)
    /// Follows the message it belongs to: where the conversation can be cut just before it.
    case checkpoint(Checkpoint)
    /// Claude Code: the conversation's last message when a turn ended, so a message sent after a
    /// resume can still be rewound to.
    case conversationHead(String)
    /// The conversation went back to just before your `message`th message (from 0). Later
    /// entries are gone from the transcript.
    case rewound(toMessage: Int)
    case assistantText(String, isFinal: Bool)
    case toolCall(ToolCall)
    case toolResult(ToolResult)

    case runState(ProviderRunState)
    case failed(FailureReason, message: String)
    case interrupted
    /// A line from Constellation itself, e.g. that it restarted and resumed the session.
    case note(String)

    case askRaised(Ask)
    case askWithdrawn(askID: String)

    case outcome(Outcome)
    case usage(TokenUsage)
    case exited(code: Int32)
}

/// The run states a provider reports directly. Failure and interruption have their own events.
public enum ProviderRunState: String, Hashable, Codable, Sendable {
    case working, blocked, done
}

public struct ToolCall: Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// One line for the tile, e.g. the shell command or the edited file.
    public var summary: String
    /// Files the call writes (Edit, Write, MultiEdit, apply_patch).
    public var files: [String]

    public init(id: String, name: String, summary: String, files: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.files = files
    }
}

public struct ToolResult: Hashable, Codable, Sendable {
    public var toolCallID: String
    public var summary: String
    public var isError: Bool

    public init(toolCallID: String, summary: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.summary = summary
        self.isError = isError
    }
}

/// Tokens and cost spent since the provider's previous usage report, plus how full the context
/// window is now. Input leaves out cached input, so the three counts add up to the total.
public struct TokenUsage: Hashable, Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    /// Claude Code reports cost; Codex doesn't.
    public var costUSD: Double?
    /// Tokens in the context after the latest model call, and the model's window.
    public var contextTokens: Int?
    public var contextWindow: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        costUSD: Double? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
    }

    public var totalTokens: Int { inputTokens + outputTokens + cachedInputTokens }
}
