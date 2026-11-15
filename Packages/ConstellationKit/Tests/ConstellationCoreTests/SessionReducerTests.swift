import Foundation
import Testing
@testable import ConstellationCore

@Suite struct SessionReducerTests {
    @Test func startedRecordsNativeIDAndLeavesPreparing() {
        let session = makeSession(runState: .preparing(.starting)).reducing(.started(nativeID: "abc"))
        #expect(session.nativeID == "abc")
        #expect(session.runState == .working)
    }

    @Test func everyEventCountsAsActivity() {
        let later = t0.addingTimeInterval(60)
        let session = makeSession().reducing(.assistantText("hi", isFinal: false), at: later)
        #expect(session.lastActivityAt == later)
    }

    @Test func toolCallsAccumulateFilesTouched() {
        let session = makeSession().reducing(
            .toolCall(ToolCall(id: "1", name: "Edit", summary: "a.swift", files: ["a.swift"])),
            .toolCall(ToolCall(id: "2", name: "Bash", summary: "ls")),
            .toolCall(ToolCall(id: "3", name: "MultiEdit", summary: "b", files: ["a.swift", "b.swift"]))
        )
        #expect(session.filesTouched == ["a.swift", "b.swift"])
    }

    @Test func doneEndsTheTurnAndMakesItUnseen() {
        let session = makeSession(runState: .working, lifecycle: .seen).reducing(.runState(.done))
        #expect(session.runState == .done)
        #expect(session.lifecycle == .unseen)
    }

    @Test func aRepeatedDoneDoesNotUndoSeen() {
        var session = makeSession().reducing(.runState(.done))
        session = LifecycleRules.apply(.dwelled, to: session, at: t0)
        session = session.reducing(.runState(.done))
        #expect(session.lifecycle == .seen)
    }

    @Test func aNewTurnAfterMergeEndsUnseen() {
        var session = makeSession(runState: .done, lifecycle: .merged)
        session = session.reducing(.userMessage("one more thing"))
        #expect(session.runState == .working)
        #expect(session.lifecycle == .merged)
        session = session.reducing(.runState(.done))
        #expect(session.lifecycle == .unseen)
    }

    @Test func userMessageStartsANewTurnAndClearsTheLastOutcome() {
        var session = makeSession(runState: .failed(.turnError))
        session.failureMessage = "boom"
        session.outcome = Outcome(status: .failed, summary: "nope")
        session = session.reducing(.userMessage("retry"))
        #expect(session.runState == .working)
        #expect(session.outcome == nil)
        #expect(session.failureMessage == nil)
    }

    @Test func userMessageWhileBlockedStaysBlocked() {
        let base = makeSession()
        let session = base.reducing(.askRaised(permissionAsk("1", session: base)), .userMessage("no, do X"))
        #expect(session.runState == .blocked)
    }

    @Test func idleAfterAnInterruptStaysInterrupted() {
        let session = makeSession(lifecycle: .seen).reducing(.interrupted, .runState(.done))
        #expect(session.runState == .interrupted)
        #expect(session.lifecycle == .seen)
    }

    @Test func failedRecordsReasonAndMessageAndEndsTheTurn() {
        let session = makeSession(lifecycle: .seen).reducing(.failed(.usageLimit, message: "limit reached"))
        #expect(session.runState == .failed(.usageLimit))
        #expect(session.failureMessage == "limit reached")
        #expect(session.lifecycle == .unseen)
    }

    @Test(arguments: [
        SessionEvent.interrupted,
        .runState(.working),
        .askRaised(Ask(id: "1", sessionID: UUID(), kind: .secret(SecretAsk(name: "KEY", reason: "r")))),
    ])
    func leavingFailedForgetsTheFailureMessage(_ event: SessionEvent) {
        let failed = makeSession().reducing(.failed(.turnError, message: "boom"))
        let session = failed.reducing(event)
        #expect(session.runState != .failed(.turnError))
        #expect(session.failureMessage == nil)
    }

    @Test func aLaterFailureReplacesTheMessage() {
        let session = makeSession().reducing(.failed(.turnError, message: "boom"), .failed(.processExited, message: "gone"))
        #expect(session.failureMessage == "gone")
    }

    @Test func aRelaunchStartsANewTurnAtTheFirstStage() {
        let later = t0.addingTimeInterval(60)
        var failed = makeSession(runState: .preparing(.setup)).reducing(.failed(.launch(.setup), message: "setup failed"))
        failed.turnStartedAt = t0
        let session = SessionReducer.relaunched(failed, at: later)
        #expect(session.runState == .preparing(.fetch))
        #expect(session.failureMessage == nil)
        #expect(session.turnStartedAt == later)
        #expect(session.turnEndedAt == nil)
    }

    @Test func readyIsDoneWithoutEndingATurn() {
        var failed = makeSession(lifecycle: .seen).reducing(.failed(.turnError, message: "boom"))
        failed.lifecycle = .seen
        let session = SessionReducer.ready(failed)
        #expect(session.runState == .done)
        #expect(session.failureMessage == nil)
        #expect(session.lifecycle == .seen)
        #expect(session.turnEndedAt == failed.turnEndedAt)
    }

    @Test func turnRunningAndEndedAreDisjoint() {
        let states: [RunState] = [.draft, .preparing(.fetch), .working, .blocked, .failed(.auth), .done, .interrupted]
        #expect(states.filter(\.isTurnRunning) == [.working, .blocked])
        #expect(states.filter(\.hasEndedTurn) == [.failed(.auth), .done])
    }

    // MARK: Asks

    @Test func asksQueueInTheOrderRaised() {
        let base = makeSession()
        let session = base.reducing(
            .askRaised(permissionAsk("b", session: base, at: t0)),
            .askRaised(permissionAsk("a", session: base, at: t0.addingTimeInterval(1))),
            .askRaised(permissionAsk("c", session: base, at: t0.addingTimeInterval(2)))
        )
        #expect(session.pendingAsks.map(\.id) == ["b", "a", "c"])
        #expect(session.nextAsk?.id == "b")
        #expect(session.runState == .blocked)
    }

    @Test func answeringTheFirstAskMovesToTheNextAndStaysBlocked() {
        let base = makeSession()
        var session = base.reducing(
            .askRaised(permissionAsk("1", session: base)),
            .askRaised(permissionAsk("2", session: base))
        )
        session = SessionReducer.answered(session, askID: "1", at: t0)
        #expect(session.nextAsk?.id == "2")
        #expect(session.runState == .blocked)
        session = SessionReducer.answered(session, askID: "2", at: t0)
        #expect(session.nextAsk == nil)
        #expect(session.runState == .working)
        #expect(session.asks.map(\.status) == [.answered, .answered])
    }

    @Test func aWithdrawnAskIsCancelledAndUnblocks() {
        let base = makeSession()
        let session = base.reducing(.askRaised(permissionAsk("1", session: base)), .askWithdrawn(askID: "1"))
        #expect(session.asks.map(\.status) == [.cancelled])
        #expect(session.runState == .working)
    }

    @Test func withdrawingOneOfTwoAsksStaysBlocked() {
        let base = makeSession()
        let session = base.reducing(
            .askRaised(permissionAsk("1", session: base)),
            .askRaised(permissionAsk("2", session: base)),
            .askWithdrawn(askID: "2")
        )
        #expect(session.pendingAsks.map(\.id) == ["1"])
        #expect(session.runState == .blocked)
    }

    @Test func aWithdrawalAfterAnsweringKeepsTheAnswer() {
        let base = makeSession()
        var session = base.reducing(.askRaised(permissionAsk("1", session: base)))
        session = SessionReducer.answered(session, askID: "1", at: t0)
        session = session.reducing(.askWithdrawn(askID: "1"))
        #expect(session.asks.map(\.status) == [.answered])
        #expect(session.runState == .working)
    }

    @Test func withdrawingAnUnknownAskChangesNothing() {
        let base = makeSession()
        let blocked = base.reducing(.askRaised(permissionAsk("1", session: base)))
        let session = blocked.reducing(.askWithdrawn(askID: "nope"))
        #expect(session.asks == blocked.asks)
        #expect(session.runState == .blocked)
    }

    @Test func reRaisingAPendingAskReplacesItInPlace() {
        let base = makeSession()
        var updated = permissionAsk("1", session: base)
        updated.kind = .secret(SecretAsk(name: "TOKEN", reason: "deploy"))
        let session = base.reducing(
            .askRaised(permissionAsk("1", session: base)),
            .askRaised(permissionAsk("2", session: base)),
            .askRaised(updated)
        )
        #expect(session.asks.count == 2)
        #expect(session.asks[0].kind == updated.kind)
    }

    @Test func aReusedIDAfterResolutionIsANewAsk() {
        let base = makeSession()
        let session = base.reducing(
            .askRaised(permissionAsk("1", session: base)),
            .askWithdrawn(askID: "1"),
            .askRaised(permissionAsk("1", session: base))
        )
        #expect(session.asks.map(\.status) == [.cancelled, .pending])
        #expect(session.runState == .blocked)
    }

    @Test func providerWorkingWhileAsksPendingStaysBlocked() {
        let base = makeSession()
        let session = base.reducing(.askRaised(permissionAsk("1", session: base)), .runState(.working))
        #expect(session.runState == .blocked)
    }

    @Test func providerBlockedBeforeTheAskArrives() {
        let session = makeSession().reducing(.runState(.blocked))
        #expect(session.runState == .blocked)
        #expect(session.pendingAsks.isEmpty)
    }

    @Test(arguments: [
        SessionEvent.runState(.done),
        .failed(.turnError, message: "x"),
        .interrupted,
        .exited(code: 1),
    ])
    func endingTheTurnCancelsPendingAsks(_ event: SessionEvent) {
        let base = makeSession()
        let session = base.reducing(.askRaised(permissionAsk("1", session: base)), event)
        #expect(session.pendingAsks.isEmpty)
        #expect(session.asks.map(\.status) == [.cancelled])
    }

    // MARK: Outcome

    @Test func aSucceededOutcomeIsKeptThroughDone() {
        let outcome = Outcome(status: .succeeded, summary: "Shipped it")
        let session = makeSession().reducing(.outcome(outcome), .runState(.done))
        #expect(session.outcome == outcome)
        #expect(session.runState == .done)
    }

    @Test func aFailedOutcomeFailsTheTurnWhenItEnds() {
        let session = makeSession().reducing(.outcome(Outcome(status: .failed, summary: "Tests still red")), .runState(.done))
        #expect(session.runState == .failed(.reportedFailure))
        #expect(session.failureMessage == "Tests still red")
        #expect(session.lifecycle == .unseen)
    }

    @Test func aFailedOutcomeArrivingAfterDoneStillFails() {
        let session = makeSession().reducing(.runState(.done), .outcome(Outcome(status: .failed, summary: "late")))
        #expect(session.runState == .failed(.reportedFailure))
    }

    @Test func aFailedOutcomeMidTurnDoesNotStopTheWork() {
        let session = makeSession().reducing(.outcome(Outcome(status: .failed, summary: "x")), .runState(.working))
        #expect(session.runState == .working)
    }

    // MARK: Process exit

    @Test func exitWhileWorkingFails() {
        let session = makeSession().reducing(.exited(code: 137))
        #expect(session.runState == .failed(.processExited))
        #expect(session.failureMessage == "Exited with code 137")
    }

    @Test func exitDuringLaunchFailsAtThatStage() {
        let session = makeSession(runState: .preparing(.starting)).reducing(.exited(code: 1))
        #expect(session.runState == .failed(.launch(.starting)))
    }

    @Test(arguments: [RunState.done, .interrupted, .failed(.auth)])
    func exitAfterTheTurnEndedChangesNothing(_ state: RunState) {
        let session = makeSession(runState: state).reducing(.exited(code: 0))
        #expect(session.runState == state)
    }

    // MARK: Restart

    @Test(arguments: [RunState.working, .blocked])
    func liveSessionsAreInterruptedOnRestart(_ state: RunState) {
        let base = makeSession(runState: state)
        let withAsk = base.reducing(.askRaised(permissionAsk("1", session: base)))
        let session = SessionReducer.recoveredAfterRestart(state == .blocked ? withAsk : base)
        #expect(session.runState == .interrupted)
        #expect(session.pendingAsks.isEmpty)
        if state == .blocked {
            #expect(session.asks.map(\.status) == [.expired])
        }
    }

    @Test func aLaunchCutShortByQuitFailsAtItsStage() {
        let session = SessionReducer.recoveredAfterRestart(makeSession(runState: .preparing(.setup)))
        #expect(session.runState == .failed(.launch(.setup)))
    }

    @Test(arguments: [RunState.done, .interrupted, .failed(.turnError)])
    func finishedSessionsSurviveRestartUnchanged(_ state: RunState) {
        let session = makeSession(runState: state, lifecycle: .seen)
        #expect(SessionReducer.recoveredAfterRestart(session) == session)
    }

    @Test func archivedSessionsAreLeftAlone() {
        let session = makeSession(runState: .working, lifecycle: .archived)
        #expect(SessionReducer.recoveredAfterRestart(session) == session)
    }
}
