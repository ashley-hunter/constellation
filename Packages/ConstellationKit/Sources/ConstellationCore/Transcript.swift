import Foundation

/// A session's conversation for the session view: your messages, the agent's text, and runs of
/// tool calls folded into one entry each.
public struct Transcript: Hashable, Sendable {
    public enum Entry: Hashable, Sendable, Identifiable {
        case user(id: Int, text: String, attachments: [Attachment] = [])
        case assistant(id: Int, text: String)
        case tools(id: Int, steps: [ToolStep])
        case outcome(id: Int, Outcome)
        case failure(id: Int, message: String)
        case interrupted(id: Int)
        case note(id: Int, text: String)

        public var id: Int {
            switch self {
            case .user(let id, _, _), .assistant(let id, _), .tools(let id, _), .outcome(let id, _),
                 .failure(let id, _), .interrupted(let id), .note(let id, _): id
            }
        }
    }

    public struct ToolStep: Hashable, Sendable {
        public var call: ToolCall
        public var result: ToolResult?
    }

    public private(set) var entries: [Entry] = []
    /// Assistant text still streaming in. The final message replaces it.
    public private(set) var streaming = ""
    /// The last file a tool call wrote, relative to the worktree when the provider gave it that way.
    public private(set) var lastWrittenFile: String?
    /// The entry ids of your messages, in order: a message's index here is what Rewind and Fork name.
    public private(set) var messageEntryIDs: [Int] = []
    /// Checkpoints by the entry id of the message they follow.
    public private(set) var checkpoints: [Int: Checkpoint] = [:]
    /// Claude Code: the conversation's last message as of the last turn's end.
    public private(set) var head: String?

    public init(_ events: some Sequence<SessionEvent> = []) {
        for event in events { append(event) }
    }

    public mutating func append(_ event: SessionEvent) {
        switch event {
        case .userMessage(let text, let attachments):
            push { .user(id: $0, text: text, attachments: attachments ?? []) }
            messageEntryIDs.append(entries.count - 1)
        case .checkpoint(var checkpoint):
            guard let message = messageEntryIDs.last else { return }
            if checkpoint.resumeAt == nil { checkpoint.resumeAt = head }
            checkpoints[message] = checkpoint
        case .conversationHead(let id):
            head = id
        case .rewound(let index):
            rewind(toMessage: index)
        case .assistantText(let text, isFinal: false):
            streaming += text
        case .assistantText(let text, isFinal: true):
            streaming = ""
            guard !text.allSatisfy(\.isWhitespace) else { return }
            push { .assistant(id: $0, text: text) }
        case .toolCall(let call):
            if let file = call.files.last { lastWrittenFile = file }
            let step = ToolStep(call: call, result: nil)
            if case .tools(let id, let steps) = entries.last {
                entries[entries.count - 1] = .tools(id: id, steps: steps + [step])
            } else {
                push { .tools(id: $0, steps: [step]) }
            }
        case .toolResult(let result):
            attach(result)
        case .outcome(let outcome):
            push { .outcome(id: $0, outcome) }
        case .failed(_, let message):
            push { .failure(id: $0, message: message) }
        case .interrupted:
            push { .interrupted(id: $0) }
        case .note(let text):
            push { .note(id: $0, text: text) }
        case .started, .runState, .askRaised, .askWithdrawn, .usage, .exited:
            break
        }
    }

    private mutating func rewind(toMessage index: Int) {
        guard messageEntryIDs.indices.contains(index) else { return }
        let entryID = messageEntryIDs[index]
        head = checkpoints[entryID]?.resumeAt
        entries.removeSubrange(entryID...)
        messageEntryIDs.removeSubrange(index...)
        checkpoints = checkpoints.filter { $0.key < entryID }
        streaming = ""
    }

    private mutating func push(_ make: (Int) -> Entry) {
        entries.append(make(entries.count))
    }

    private mutating func attach(_ result: ToolResult) {
        for index in entries.indices.reversed() {
            guard case .tools(let id, var steps) = entries[index],
                  let step = steps.lastIndex(where: { $0.call.id == result.toolCallID }) else { continue }
            steps[step].result = result
            entries[index] = .tools(id: id, steps: steps)
            return
        }
    }
}

// MARK: Rewind and Fork

extension Transcript {
    /// The index of your message at this entry, for Rewind to here and Fork from here.
    public func messageIndex(ofEntry id: Int) -> Int? {
        messageEntryIDs.firstIndex(of: id)
    }

    public func checkpoint(forMessage index: Int) -> Checkpoint? {
        messageEntryIDs.indices.contains(index) ? checkpoints[messageEntryIDs[index]] : nil
    }

    /// Where the provider cuts the conversation to go back to just before a message. Nil when the
    /// message has no checkpoint, e.g. a Codex steer, which joins a turn already running.
    public func rewindCut(toMessage index: Int, provider: Provider) -> ConversationCut? {
        guard let checkpoint = checkpoint(forMessage: index) else { return nil }
        switch provider {
        case .claudeCode:
            return checkpoint.turnID == nil ? nil : .rewind(before: checkpoint.resumeAt)
        case .codex:
            return checkpoint.turnID.map { .rewind(before: $0) }
        }
    }

    /// Where the provider cuts the conversation to copy it through a message's turn.
    public func forkCut(atMessage index: Int, provider: Provider) -> ConversationCut? {
        guard let checkpoint = checkpoint(forMessage: index), checkpoint.turnID != nil else { return nil }
        switch provider {
        case .claudeCode:
            // The turn ends where the next message picks up, or at the head for the last one.
            let next = (index + 1..<messageEntryIDs.count).lazy.compactMap { self.checkpoint(forMessage: $0) }.first
            return .fork(through: next?.resumeAt ?? head)
        case .codex:
            return .fork(through: checkpoint.turnID)
        }
    }

    /// The events a fork starts with: the conversation through a message's turn, stopping where the
    /// next message begins, without process, run-state and ask bookkeeping.
    public static func history(_ events: [SessionEvent], throughMessage index: Int) -> [SessionEvent] {
        // Where each message of the final conversation was sent; a rewind forgets the later ones.
        var sentAt: [Int] = []
        for (position, event) in events.enumerated() {
            switch event {
            case .userMessage: sentAt.append(position)
            case .rewound(let message): sentAt.removeSubrange(min(message, sentAt.count)...)
            default: break
            }
        }
        let end = sentAt.indices.contains(index + 1) ? sentAt[index + 1] : events.count
        return events[..<end].filter { event in
            switch event {
            case .started, .runState, .askRaised, .askWithdrawn, .usage, .exited, .assistantText(_, isFinal: false): false
            default: true
            }
        }
    }

    /// What going back to just before a message loses: that message and every later one.
    public func messagesLost(rewindingTo index: Int) -> Int {
        max(0, messageEntryIDs.count - index)
    }
}
