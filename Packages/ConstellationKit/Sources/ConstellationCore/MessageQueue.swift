import Foundation

/// A message waiting for the session's turn to end.
public struct QueuedMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var message: UserMessage
    public var createdAt: Date

    public init(id: UUID = UUID(), sessionID: UUID, message: UserMessage, createdAt: Date = .now) {
        self.id = id
        self.sessionID = sessionID
        self.message = message
        self.createdAt = createdAt
    }
}

/// What sending from the composer does, by run state.
public enum SendRoute: Hashable, Sendable {
    /// Start a new turn, resuming the provider first if its process is gone.
    case startTurn
    /// Wait for the current turn to end.
    case queue
    /// Reach the running turn now.
    case steer
    /// Answer the pending ask in words.
    case answerAsk
}

extension Session {
    /// While working, a message queues unless you steer (⌘↵). Before the provider is up there is
    /// nothing to steer, so it queues either way.
    public func sendRoute(steer: Bool) -> SendRoute {
        if nextAsk != nil { return .answerAsk }
        switch runState {
        case .preparing: return .queue
        case .working, .blocked: return steer ? .steer : .queue
        case .draft, .done, .failed, .interrupted: return .startTurn
        }
    }
}

public enum MessageQueue {
    /// The queue flushes, one message per turn, when a turn finishes. A failed or interrupted turn
    /// leaves it waiting for you.
    public static func shouldFlush(from before: RunState, to after: RunState) -> Bool {
        before != .done && after == .done
    }
}

extension Array where Element == QueuedMessage {
    /// Moves a message `offset` places, clamped to the ends.
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        let target = Swift.min(Swift.max(index + offset, 0), count - 1)
        guard target != index else { return }
        insert(remove(at: index), at: target)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> QueuedMessage? {
        guard let index = firstIndex(where: { $0.id == id }) else { return nil }
        return remove(at: index)
    }
}
