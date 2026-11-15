import Foundation

/// One line of a tile's live output.
public struct OutputLine: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case dim, text, highlight, ask, error
    }

    public var text: String
    public var tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }
}

/// The last few lines a session printed: tool calls and the latest assistant text.
///
/// A turn's failure shows once. Providers often report it twice (a failed result, then the process
/// exiting non-zero), and its message often repeats the line just above it, such as a command's
/// "Exit code 254".
public struct LiveOutput: Hashable, Sendable {
    public static let capacity = 12

    public private(set) var lines: [OutputLine] = []
    /// Assistant text still streaming in, shown after `lines` until its final message arrives.
    public private(set) var streaming = ""
    /// The current turn's failure is already among `lines`, so nothing needs to repeat it.
    public private(set) var showsFailure = false
    /// What the session is doing now, in words: its latest tool call ("Editing LoginView.swift"),
    /// until it finishes a reply or is sent a new message.
    public private(set) var activity: String?
    /// The last line of its latest finished reply.
    public private(set) var lastReply: String?

    public init() {}

    /// The newest `count` lines, the streaming text last.
    public func tail(_ count: Int) -> [OutputLine] {
        var all = lines
        if let last = Self.lastLine(of: streaming) {
            all.append(OutputLine(text: last, tone: .text))
        }
        return Array(all.suffix(count))
    }

    public mutating func append(_ event: SessionEvent) {
        switch event {
        case .userMessage(let text, let attachments):
            showsFailure = false
            activity = nil
            let attached = (attachments ?? []).isEmpty ? "" : " " + Self.attachmentLabel(attachments ?? [])
            push("› " + (Self.lastLine(of: text) ?? "") + attached, .dim)
        case .assistantText(let text, isFinal: false):
            streaming += text
        case .assistantText(let text, isFinal: true):
            streaming = ""
            activity = nil
            if let last = Self.lastLine(of: text) {
                push(last, .text)
                lastReply = last
            }
        case .toolCall(let call):
            if let words = call.activity { activity = words }
            push(call.name == "Bash" ? "$ \(call.summary)" : "● \(call.name) \(call.summary)", .dim)
        case .toolResult(let result):
            guard let line = Self.lastLine(of: result.summary) else { return }
            push("  " + line, result.isError ? .error : .text)
        case .askRaised(let ask):
            push(ask.kind.headline, .ask)
        case .failed(_, let message):
            pushFailure(Self.lastLine(of: message) ?? "Failed")
        case .interrupted:
            push("Interrupted", .dim)
        case .note(let text):
            push(text, .dim)
        case .outcome(let outcome):
            let failed = outcome.status == .failed
            push((failed ? "✕ " : "✓ ") + outcome.summary, failed ? .error : .highlight)
            if failed { showsFailure = true }
        case .exited(let code) where code != 0:
            pushFailure("Exited with code \(code)")
        case .rewound:
            push("Rewound", .dim)
        case .started, .runState, .askWithdrawn, .usage, .exited, .checkpoint, .conversationHead:
            break
        }
    }

    /// The first report of a turn's failure, unless the line above already says it.
    private mutating func pushFailure(_ text: String) {
        defer { showsFailure = true }
        guard !showsFailure else { return }
        if let last = lines.last, last.text.trimmingCharacters(in: .whitespaces) == text {
            lines[lines.count - 1].tone = .error
            return
        }
        push(text, .error)
    }

    private mutating func push(_ text: String, _ tone: OutputLine.Tone) {
        lines.append(OutputLine(text: text, tone: tone))
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    /// "[1 image]", "[2 files]", "[1 image, 1 file]".
    public static func attachmentLabel(_ attachments: [Attachment]) -> String {
        let images = attachments.count { $0.kind == .image }
        let files = attachments.count - images
        var parts: [String] = []
        if images > 0 { parts.append("\(images) \(images == 1 ? "image" : "images")") }
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    public static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .last { !$0.allSatisfy(\.isWhitespace) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

extension AskKind {
    /// One line for a tile.
    public var headline: String {
        switch self {
        case .permission(let ask): ask.toolName == "Bash" ? "Run \(ask.summary)?" : "\(ask.toolName): \(ask.summary)"
        case .question(let ask): ask.questions.first?.prompt ?? "Question"
        case .secret(let ask): "Needs \(ask.name)"
        }
    }
}
