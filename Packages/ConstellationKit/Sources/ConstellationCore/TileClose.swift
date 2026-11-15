import Foundation

/// What ⌘W does to a tile: a terminal closes and its shell stops, a draft is discarded (asking
/// first only when something is written in it), and a session is archived (asking first only
/// while it is preparing, working or waiting on you).
public enum TileClose: Hashable, Sendable {
    case closeTerminal(UUID)
    case discardDraft(UUID, asks: Bool)
    case archive(UUID, asks: Bool)

    /// `session` is the tile's session when it is one; nil for a terminal or a session that is gone.
    public static func route(_ item: TileItem, session: Session?, draftIsEmpty: Bool) -> TileClose? {
        switch item {
        case .terminal(let id):
            return .closeTerminal(id)
        case .session(let id):
            guard let session, session.lifecycle != .archived else { return nil }
            if session.isDraft { return .discardDraft(id, asks: !draftIsEmpty) }
            return .archive(id, asks: asksBeforeArchiving(session.runState))
        }
    }

    /// Archiving stops the agent, so it asks while one is busy or blocked. Finished, failed and
    /// interrupted work goes straight away.
    public static func asksBeforeArchiving(_ runState: RunState) -> Bool {
        switch runState {
        case .preparing, .working, .blocked: true
        case .draft, .done, .failed, .interrupted: false
        }
    }
}
