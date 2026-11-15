import Foundation

/// Working through everything that needs you, one session at a time.
public enum Triage {
    /// The sessions triage opens, in order: waiting on you (the oldest ask first), then failed and
    /// not yet seen, then done and not yet seen (each the longest quiet first). Archived sessions
    /// and drafts are left out.
    public static func queue(_ sessions: some Sequence<Session>) -> [UUID] {
        var blocked: [(Session, Date)] = []
        var failed: [(Session, Date)] = []
        var done: [(Session, Date)] = []
        for session in sessions where session.lifecycle != .archived && !session.isDraft {
            switch session.runState {
            case .blocked:
                blocked.append((session, session.nextAsk?.createdAt ?? session.lastActivityAt))
            case .failed where session.lifecycle == .unseen:
                failed.append((session, session.lastActivityAt))
            case .done where session.lifecycle == .unseen:
                done.append((session, session.lastActivityAt))
            default:
                break
            }
        }
        // The id breaks a tie, so the order never shuffles between calls.
        func oldestFirst(_ list: [(Session, Date)]) -> [UUID] {
            list.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id.uuidString < $1.0.id.uuidString }.map(\.0.id)
        }
        return oldestFirst(blocked) + oldestFirst(failed) + oldestFirst(done)
    }
}
