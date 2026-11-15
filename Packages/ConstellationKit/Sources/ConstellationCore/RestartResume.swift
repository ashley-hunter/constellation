import Foundation

/// A session that was live when Constellation went away and picks itself back up at launch with
/// the provider's own resume.
public struct RestartResume: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// It was mid-turn: the turn carries on.
        case midTurn
        /// It was waiting on you. The provider's pending ask went with its process, so it waits
        /// for your reply in words.
        case waiting(Ask?)
    }

    public var sessionID: UUID
    public var kind: Kind

    public init(sessionID: UUID, kind: Kind) {
        self.sessionID = sessionID
        self.kind = kind
    }

    /// More than this many stay interrupted for you to resume by hand, so a launch doesn't start
    /// a crowd of agents at once.
    public static let limit = 6

    /// Which of the sessions as stored (before the restart rule) resume, most recently active first.
    /// Only working and blocked ones that have a native id do: anything you stopped is already
    /// interrupted, and archived sessions stay put.
    public static func plan(for sessions: [Session], limit: Int = limit) -> [RestartResume] {
        sessions
            .filter { $0.lifecycle != .archived && $0.nativeID != nil }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .compactMap { session -> RestartResume? in
                switch session.runState {
                case .working: RestartResume(sessionID: session.id, kind: .midTurn)
                case .blocked: RestartResume(sessionID: session.id, kind: .waiting(session.nextAsk))
                case .draft, .preparing, .failed, .done, .interrupted: nil
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The line the transcript shows when it picks up.
    public var note: String {
        switch kind {
        case .midTurn:
            "Constellation restarted; picked up where it left off."
        case .waiting(let ask?):
            "Constellation restarted while this waited on you (\(ask.kind.headline)), so it asks again."
        case .waiting(nil):
            "Constellation restarted while this waited on you, so it asks again."
        }
    }

    /// Sent to a session resumed mid-turn so the provider carries on.
    public static let continuation = "Constellation restarted while you were working. Carry on where you left off."

    /// Sent to a session resumed while it waited on you: its ask went with the old process, so it
    /// tries that step again and the same ask comes back to answer.
    public static let askAgain = "Constellation restarted before you got an answer. Try that last step again, asking again where you need to."
}
