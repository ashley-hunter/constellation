import Foundation
import Testing
@testable import ConstellationCore

@Suite struct TriageTests {
    private func blocked(askedAt date: Date, createdAt: Date = t0) -> Session {
        var session = makeSession(createdAt: createdAt, runState: .blocked)
        session.asks = [permissionAsk("a", session: session, at: date)]
        return session
    }

    private func ended(_ state: RunState, at date: Date, lifecycle: Lifecycle = .unseen) -> Session {
        var session = makeSession(runState: state, lifecycle: lifecycle)
        session.lastActivityAt = date
        return session
    }

    @Test func waitingComesFirstThenFailedThenDoneEachOldestFirst() {
        let doneOld = ended(.done, at: t0 + 1)
        let doneNew = ended(.done, at: t0 + 9)
        let failedNew = ended(.failed(.turnError), at: t0 + 8)
        let failedOld = ended(.failed(.processExited), at: t0 + 2)
        let askedLate = blocked(askedAt: t0 + 7)
        let askedEarly = blocked(askedAt: t0 + 3, createdAt: t0 + 5)
        let queue = Triage.queue([doneNew, failedNew, askedLate, doneOld, askedEarly, failedOld])
        #expect(queue == [askedEarly.id, askedLate.id, failedOld.id, failedNew.id, doneOld.id, doneNew.id])
    }

    @Test func seenWorkWorkingArchivedAndDraftsAreLeftOut() {
        var archived = blocked(askedAt: t0)
        archived.lifecycle = .archived
        let sessions = [
            ended(.done, at: t0, lifecycle: .seen),
            ended(.failed(.turnError), at: t0, lifecycle: .seen),
            ended(.interrupted, at: t0),
            makeSession(runState: .working),
            makeSession(runState: .draft),
            archived,
        ]
        #expect(Triage.queue(sessions).isEmpty)
    }

    @Test func aWaitingSessionCountsHoweverLongAgoYouSawIt() {
        var session = blocked(askedAt: t0)
        session.lifecycle = .seen
        #expect(Triage.queue([session]) == [session.id])
    }
}
