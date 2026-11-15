import Foundation
import Testing
@testable import ConstellationCore

@Suite struct DraftSessionTests {
    @Test(arguments: [LifecycleEvent.dwelled, .tick, .turnEnded, .pullRequestMerged])
    func aDraftNeverRecedes(_ event: LifecycleEvent) {
        let draft = makeSession(createdAt: t0, runState: .draft)
        let later = t0.addingTimeInterval(LifecycleRules.idleAfter * 2)
        #expect(LifecycleRules.apply(event, to: draft, at: later) == draft)
    }

    @Test func aDraftDrawsFullSize() {
        #expect(LifecycleRules.presentation(of: makeSession(runState: .draft)) == .full)
    }

    @Test func sendingADraftStartsItsFirstTurn() {
        #expect(makeSession(runState: .draft).sendRoute(steer: false) == .startTurn)
        #expect(makeSession(runState: .draft).sendRoute(steer: true) == .startTurn)
    }

    @Test func aDraftHasNoElapsedTime() {
        #expect(makeSession(runState: .draft).elapsed(at: t0.addingTimeInterval(60)) == nil)
    }

    @Test func aDraftSurvivesARestart() {
        let draft = makeSession(runState: .draft)
        #expect(SessionReducer.recoveredAfterRestart(draft).runState == .draft)
    }
}
