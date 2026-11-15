import Foundation
import Testing
@testable import ConstellationCore

@Suite struct ElapsedTimeTests {
    @Test func countsFromLaunchWhilePreparing() {
        let session = makeSession(createdAt: t0, runState: .preparing(.worktree))
        #expect(session.elapsed(at: t0.addingTimeInterval(12)) == 12)
    }

    @Test func countsFromTheTurnNotFromCreation() {
        // Created long ago, as a restored or resumed session is: the turn started 20s before now.
        var session = makeSession(createdAt: t0, runState: .preparing(.starting))
        let launched = t0.addingTimeInterval(600)
        session = session.reducing(.started(nativeID: "n"), at: launched)
        #expect(session.elapsed(at: launched.addingTimeInterval(20)) == 20)
        #expect(ElapsedTime.label(session.elapsed(at: launched.addingTimeInterval(20))!) == "20s")
    }

    @Test func aFollowUpStartsANewTurnAndAnsweringDoesNot() {
        var session = makeSession(runState: .preparing(.starting))
            .reducing(.started(nativeID: "n"), at: t0)
            .reducing(.runState(.done), at: t0.addingTimeInterval(90))
        #expect(session.elapsed(at: t0.addingTimeInterval(500)) == 90, "a done tile shows how long its turn took")

        let followUp = t0.addingTimeInterval(1_000)
        session = session.reducing(.userMessage("again"), at: followUp)
        #expect(session.runState == .working)
        #expect(session.turnEndedAt == nil)
        #expect(session.elapsed(at: followUp.addingTimeInterval(5)) == 5)

        let ask = Ask(id: "a", sessionID: session.id, kind: .secret(SecretAsk(name: "TOKEN", reason: "")))
        session = session.reducing(.askRaised(ask), at: followUp.addingTimeInterval(10))
        session = SessionReducer.answered(session, askID: "a", at: followUp.addingTimeInterval(30))
        session = session.reducing(.runState(.working), at: followUp.addingTimeInterval(31))
        #expect(session.elapsed(at: followUp.addingTimeInterval(40)) == 40)
    }

    @Test func resumingAnInterruptedSessionStartsATurn() {
        var session = makeSession(runState: .interrupted)
        #expect(session.elapsed(at: t0) == nil)
        session = session.reducing(.runState(.working), at: t0.addingTimeInterval(300))
        #expect(session.elapsed(at: t0.addingTimeInterval(302)) == 2)
    }

    @Test func aRestoredSessionWithNoTurnTimesShowsNone() {
        #expect(makeSession(runState: .working).elapsed(at: t0) == nil)
        #expect(makeSession(runState: .done).elapsed(at: t0) == nil)
    }

    @Test(arguments: [
        (0.0, "0s"), (20.4, "20s"), (59.9, "59s"), (60, "1m"), (119, "1m"), (3_599, "59m"),
        (3_600, "1h"), (3_900, "1h 5m"), (86_399, "23h 59m"), (172_800, "2d"), (-3, "0s"),
    ])
    func labelsRoundDown(interval: TimeInterval, label: String) {
        #expect(ElapsedTime.label(interval) == label)
    }
}
