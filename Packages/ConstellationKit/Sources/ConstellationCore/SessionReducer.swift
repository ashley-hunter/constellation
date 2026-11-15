import Foundation

public enum SessionReducer {
    /// Applies a normalized provider event to run state, asks, outcome and files touched.
    /// Every event counts as activity.
    public static func reduce(_ session: Session, _ event: SessionEvent, at now: Date = .now) -> Session {
        var after = transition(session, event, at: now)
        if !session.runState.isTurnRunning, after.runState.isTurnRunning {
            after.turnStartedAt = now
            after.turnEndedAt = nil
            after = LifecycleRules.apply(.turnStarted, to: after, at: now)
        }
        // The message describes a failure, so it goes once the session leaves failed.
        if case .failed = after.runState {} else { after.failureMessage = nil }
        return after
    }

    /// A failed launch starting over from its first stage, as a new turn.
    public static func relaunched(_ session: Session, at now: Date = .now) -> Session {
        var session = session
        session.runState = .preparing(.fetch)
        session.turnStartedAt = now
        session.turnEndedAt = nil
        session.failureMessage = nil
        return session
    }

    /// Waiting for your next message without a turn having run: after a rewind, or a resume with
    /// nothing to send. Unlike the provider's done it leaves the lifecycle and turn times alone.
    public static func ready(_ session: Session) -> Session {
        var session = session
        session.runState = .done
        session.failureMessage = nil
        return session
    }

    private static func transition(_ session: Session, _ event: SessionEvent, at now: Date) -> Session {
        var session = session
        session.lastActivityAt = now

        switch event {
        case .started(let nativeID):
            session.nativeID = nativeID
            if case .preparing = session.runState {
                session.runState = .working
            }

        case .userMessage:
            session.outcome = nil
            session.failureMessage = nil
            switch session.runState {
            case .done, .failed, .interrupted:
                session.runState = .working
            case .draft, .preparing, .working, .blocked:
                break
            }

        case .assistantText, .toolResult, .usage, .checkpoint, .conversationHead, .note:
            break

        case .rewound:
            session.outcome = nil

        case .toolCall(let call):
            session.filesTouched.formUnion(call.files)

        case .runState(.working):
            session.runState = session.pendingAsks.isEmpty ? .working : .blocked

        case .runState(.blocked):
            session.runState = .blocked

        case .runState(.done):
            // Providers report idle after an interrupt; the session stays interrupted.
            guard session.runState != .interrupted else { break }
            session.close(pendingAsksAs: .cancelled)
            if session.outcome?.status == .failed {
                session.endTurn(.failed(.reportedFailure), message: session.outcome?.summary, at: now)
            } else {
                session.endTurn(.done, at: now)
            }

        case .failed(let reason, let message):
            session.close(pendingAsksAs: .cancelled)
            session.endTurn(.failed(reason), message: message, at: now)

        case .interrupted:
            session.close(pendingAsksAs: .cancelled)
            session.runState = .interrupted

        case .askRaised(let ask):
            var ask = ask
            ask.status = .pending
            if let index = session.pendingIndex(of: ask.id) {
                session.asks[index] = ask
            } else {
                session.asks.append(ask)
            }
            session.runState = .blocked

        case .askWithdrawn(let askID):
            session.resolve(askID, as: .cancelled)

        case .outcome(let outcome):
            session.outcome = outcome
            // report_outcome arrives over the MCP socket and can land after the turn has ended.
            if outcome.status == .failed, session.runState == .done {
                session.runState = .failed(.reportedFailure)
                session.failureMessage = outcome.summary
            }

        case .exited(let code):
            switch session.runState {
            case .preparing(let stage):
                session.close(pendingAsksAs: .cancelled)
                session.endTurn(.failed(.launch(stage)), message: "Exited with code \(code)", at: now)
            case .working, .blocked:
                session.close(pendingAsksAs: .cancelled)
                session.endTurn(.failed(.processExited), message: "Exited with code \(code)", at: now)
            case .draft, .done, .failed, .interrupted:
                break
            }
        }
        return session
    }

    /// Records your answer to a pending ask. The provider carries on, so the session works again
    /// once nothing else is pending.
    public static func answered(_ session: Session, askID: String, at now: Date = .now) -> Session {
        var session = session
        session.lastActivityAt = now
        session.resolve(askID, as: .answered)
        return session
    }

    /// What a session looks like when Constellation launches again: its process is gone.
    /// Working and blocked sessions become interrupted, a launch in progress fails at its stage,
    /// and pending asks expire because the agent asks again after resume.
    public static func recoveredAfterRestart(_ session: Session) -> Session {
        guard session.lifecycle != .archived else { return session }
        var session = session
        session.close(pendingAsksAs: .expired)
        switch session.runState {
        case .working, .blocked:
            session.runState = .interrupted
        case .preparing(let stage):
            session.runState = .failed(.launch(stage))
            session.failureMessage = "Constellation quit during launch"
        case .draft, .done, .failed, .interrupted:
            break
        }
        return session
    }
}

extension Session {
    fileprivate func pendingIndex(of askID: String) -> Int? {
        asks.firstIndex { $0.id == askID && $0.status == .pending }
    }

    fileprivate mutating func resolve(_ askID: String, as status: AskStatus) {
        guard let index = pendingIndex(of: askID) else { return }
        asks[index].status = status
        if runState == .blocked, pendingAsks.isEmpty {
            runState = .working
        }
    }

    fileprivate mutating func close(pendingAsksAs status: AskStatus) {
        for index in asks.indices where asks[index].status == .pending {
            asks[index].status = status
        }
    }

    /// A turn ends once: repeated end-of-turn frames don't undo a tile you have already seen.
    fileprivate mutating func endTurn(_ state: RunState, message: String? = nil, at now: Date) {
        let wasEnded = runState.hasEndedTurn
        runState = state
        failureMessage = message
        if !wasEnded {
            turnEndedAt = now
            self = LifecycleRules.apply(.turnEnded, to: self, at: now)
        }
    }
}
