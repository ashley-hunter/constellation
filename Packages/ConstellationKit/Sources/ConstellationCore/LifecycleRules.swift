import Foundation

/// Things that move a session's lifecycle, reported by the provider, the UI, GitHub or clean-up.
public enum LifecycleEvent: Hashable, Sendable {
    case turnEnded
    /// A turn started: work put away by hand or settled comes back out while it runs.
    case turnStarted
    /// The tile has been focused or hovered for `LifecycleRules.seenDwell`.
    case dwelled
    /// You've looked at it and moved on: no focus, pointer or open panel on it for
    /// `LifecycleRules.settleGrace`, or Constellation launched with it seen.
    case movedOn
    /// Put away by hand with Settle.
    case settled
    case pullRequestMerged
    case cleanupConfirmed
    /// Periodic check for sessions that have gone idle.
    case tick
    /// Brought back out of the Settled tray by hand: seen again, kept on its worktree's pile until
    /// its next turn, a merge or a day without activity.
    case unsettled
}

/// How a tile draws, from its run state and lifecycle.
public enum TilePresentation: Hashable, Sendable {
    case full
    case titleBar
    case pebble
    case faded
    case hidden
}

public enum LifecycleRules {
    public static let seenDwell: Duration = .seconds(1)
    /// How long finished, seen work waits after you move on from it before it settles.
    public static let settleGrace: Duration = .seconds(2)
    public static let idleAfter: TimeInterval = 24 * 60 * 60

    /// Archived is final. Otherwise a session only moves further from your attention,
    /// except that a finished turn always brings it back to unseen.
    ///
    /// Seen work settles once you've looked at it and moved on, so the desktop holds mainly live
    /// work. Only done work settles by itself: an interrupted session waits for you to resume it or
    /// settle it by hand.
    public static func apply(_ event: LifecycleEvent, to session: Session, at now: Date = .now) -> Session {
        guard session.lifecycle != .archived, !session.isDraft else { return session }
        var session = session
        switch event {
        case .turnEnded:
            session.lifecycle = .unseen
        case .turnStarted:
            if session.lifecycle == .kept || session.lifecycle == .settled {
                session.lifecycle = .seen
            }
        case .dwelled:
            session.lastSeenAt = now
            if session.lifecycle == .unseen {
                session.lifecycle = .seen
            }
        case .movedOn:
            if session.runState == .done, session.lifecycle == .seen {
                session.lifecycle = .settled
            }
        case .settled:
            guard canSettle(session) else { return session }
            session.lastSeenAt = now
            session.lifecycle = .settled
        case .pullRequestMerged:
            if [.unseen, .seen, .kept, .settled].contains(session.lifecycle) {
                session.lifecycle = .merged
            }
        case .cleanupConfirmed:
            session.lifecycle = .archived
        case .tick:
            if session.lifecycle != .idle, now.timeIntervalSince(session.lastActivityAt) >= idleAfter {
                session.lifecycle = .idle
            }
        case .unsettled:
            guard isSettled(session) else { return session }
            session.lifecycle = .kept
            session.lastSeenAt = now
            // Its day before settling again starts now.
            session.lastActivityAt = max(session.lastActivityAt, now)
        }
        return session
    }

    /// Finished work still on its worktree's pile, which Settle can put away.
    public static func canSettle(_ session: Session) -> Bool {
        guard session.runState == .done || session.runState == .interrupted else { return false }
        return [.unseen, .seen, .kept].contains(session.lifecycle)
    }

    /// In the Settled tray: Unsettle brings it back.
    public static func isSettled(_ session: Session) -> Bool {
        [.settled, .merged, .idle].contains(session.lifecycle)
    }

    /// Blocked and failed sessions always draw full size, whatever the lifecycle says.
    /// Live sessions draw full too, and so does finished work until it settles.
    public static func presentation(of session: Session) -> TilePresentation {
        if session.lifecycle == .archived { return .hidden }
        switch session.runState {
        case .draft, .preparing, .working, .blocked, .failed:
            return .full
        case .done, .interrupted:
            switch session.lifecycle {
            case .unseen, .seen, .kept: return .full
            case .settled, .merged: return .pebble
            case .idle: return .faded
            case .archived: return .hidden
            }
        }
    }
}
