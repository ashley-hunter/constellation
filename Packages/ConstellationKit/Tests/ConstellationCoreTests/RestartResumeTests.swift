import Foundation
import Testing
@testable import ConstellationCore

@Suite struct RestartResumeTests {
    private func live(_ state: RunState, nativeID: String? = "native", lifecycle: Lifecycle = .unseen, active: TimeInterval = 0) -> Session {
        var session = makeSession(runState: state, lifecycle: lifecycle)
        session.nativeID = nativeID
        session.lastActivityAt = t0.addingTimeInterval(active)
        return session
    }

    @Test func workingSessionsCarryOnAndBlockedOnesWaitWithTheirAsk() {
        let working = live(.working)
        let base = live(.blocked)
        let blocked = base.reducing(.askRaised(permissionAsk("1", session: base)))
        let plan = RestartResume.plan(for: [working, blocked])
        #expect(plan.first { $0.sessionID == working.id }?.kind == .midTurn)
        #expect(plan.first { $0.sessionID == blocked.id }?.kind == .waiting(blocked.nextAsk))
    }

    @Test(arguments: [RunState.interrupted, .done, .draft, .preparing(.setup), .failed(.turnError)])
    func sessionsThatWerentLiveStayAsTheyAre(_ state: RunState) {
        #expect(RestartResume.plan(for: [live(state)]).isEmpty)
    }

    @Test func archivedSessionsAndOnesWithoutANativeIDDontResume() {
        let archived = live(.working, lifecycle: .archived)
        let unnamed = live(.working, nativeID: nil)
        #expect(RestartResume.plan(for: [archived, unnamed]).isEmpty)
    }

    @Test func onlyTheMostRecentlyActiveResumeUpToTheLimit() {
        let sessions = (0..<5).map { live(.working, active: TimeInterval($0)) }
        let plan = RestartResume.plan(for: sessions, limit: 3)
        #expect(plan.map(\.sessionID) == sessions.reversed().prefix(3).map(\.id))
    }

    @Test func theNoteNamesTheAskThatWentAway() {
        let base = live(.blocked)
        let ask = permissionAsk("1", session: base)
        #expect(RestartResume(sessionID: base.id, kind: .waiting(ask)).note.contains("Run rm -rf build?"))
        #expect(RestartResume(sessionID: base.id, kind: .midTurn).note == "Constellation restarted; picked up where it left off.")
    }

    @Test func aNoteShowsInTheTranscriptWithoutChangingTheRunState() {
        let session = live(.interrupted).reducing(.note("Constellation restarted"))
        #expect(session.runState == .interrupted)
        #expect(Transcript([.note("Constellation restarted")]).entries == [.note(id: 0, text: "Constellation restarted")])
    }
}
