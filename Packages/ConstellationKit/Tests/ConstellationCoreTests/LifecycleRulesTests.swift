import Foundation
import Testing
@testable import ConstellationCore

@Suite struct LifecycleRulesTests {
    @Test func turnEndedMakesAnySessionUnseen() {
        for lifecycle in [Lifecycle.unseen, .seen, .kept, .settled, .merged, .idle] {
            let session = LifecycleRules.apply(.turnEnded, to: makeSession(lifecycle: lifecycle))
            #expect(session.lifecycle == .unseen)
        }
    }

    @Test func dwellingMakesUnseenSeen() {
        let later = t0.addingTimeInterval(5)
        let session = LifecycleRules.apply(.dwelled, to: makeSession(runState: .done), at: later)
        #expect(session.lifecycle == .seen)
        #expect(session.lastSeenAt == later)
    }

    @Test(arguments: [Lifecycle.settled, .merged, .idle])
    func dwellingNeverBringsRecededWorkBack(_ lifecycle: Lifecycle) {
        let session = LifecycleRules.apply(.dwelled, to: makeSession(lifecycle: lifecycle), at: t0)
        #expect(session.lifecycle == lifecycle)
        #expect(session.lastSeenAt == t0)
    }

    @Test(arguments: [Lifecycle.unseen, .seen, .kept, .settled])
    func aMergedPRMakesItMerged(_ lifecycle: Lifecycle) {
        let session = LifecycleRules.apply(.pullRequestMerged, to: makeSession(lifecycle: lifecycle))
        #expect(session.lifecycle == .merged)
    }

    @Test func aMergedPRDoesNotPullIdleWorkForward() {
        let session = LifecycleRules.apply(.pullRequestMerged, to: makeSession(lifecycle: .idle))
        #expect(session.lifecycle == .idle)
    }

    // MARK: Settling once seen

    @Test func seenDoneWorkSettlesOnceYouMoveOn() {
        let session = LifecycleRules.apply(.movedOn, to: makeSession(runState: .done, lifecycle: .seen))
        #expect(session.lifecycle == .settled)
        #expect(LifecycleRules.presentation(of: session) == .pebble)
    }

    @Test(arguments: [Lifecycle.unseen, .kept])
    func movingOnLeavesUnseenAndKeptWorkOut(_ lifecycle: Lifecycle) {
        let session = LifecycleRules.apply(.movedOn, to: makeSession(runState: .done, lifecycle: lifecycle))
        #expect(session.lifecycle == lifecycle)
    }

    /// Interrupted work waits for you to resume it, and live or failed work never settles by itself.
    @Test(arguments: [RunState.interrupted, .working, .blocked, .failed(.turnError), .preparing(.setup)])
    func onlyDoneWorkSettlesByItself(_ state: RunState) {
        let session = LifecycleRules.apply(.movedOn, to: makeSession(runState: state, lifecycle: .seen))
        #expect(session.lifecycle == .seen)
    }

    @Test(arguments: [
        (RunState.done, Lifecycle.unseen), (.done, .seen), (.done, .kept), (.interrupted, .seen), (.interrupted, .unseen),
    ])
    func settleByHandPutsFinishedWorkAway(_ state: RunState, _ lifecycle: Lifecycle) {
        let session = LifecycleRules.apply(.settled, to: makeSession(runState: state, lifecycle: lifecycle), at: t0)
        #expect(session.lifecycle == .settled)
        #expect(LifecycleRules.presentation(of: session) == .pebble)
        #expect(session.lastSeenAt != nil)
    }

    @Test(arguments: [RunState.working, .blocked, .failed(.turnError), .draft])
    func settleByHandLeavesUnfinishedWorkAlone(_ state: RunState) {
        let session = makeSession(runState: state, lifecycle: .seen)
        #expect(!LifecycleRules.canSettle(session))
        #expect(LifecycleRules.apply(.settled, to: session) == session)
    }

    /// Unsettle isn't undone the moment you look away: kept work stays out until its next turn.
    @Test(arguments: [Lifecycle.settled, .merged, .idle])
    func unsettledWorkIsKeptOutUntilItsNextTurn(_ lifecycle: Lifecycle) {
        let back = LifecycleRules.apply(.unsettled, to: makeSession(runState: .done, lifecycle: lifecycle), at: t0 + 60)
        #expect(back.lifecycle == .kept)
        #expect(back.lastActivityAt == t0 + 60)
        #expect(LifecycleRules.presentation(of: back) == .full)
        #expect(LifecycleRules.apply(.movedOn, to: back).lifecycle == .kept)
        let again = LifecycleRules.apply(.dwelled, to: LifecycleRules.apply(.turnEnded, to: back))
        #expect(LifecycleRules.apply(.movedOn, to: again).lifecycle == .settled)
        #expect(LifecycleRules.apply(.settled, to: back).lifecycle == .settled)
    }

    @Test func aTurnStartingBringsSettledWorkBackOut() {
        for lifecycle in [Lifecycle.settled, .kept] {
            #expect(LifecycleRules.apply(.turnStarted, to: makeSession(runState: .working, lifecycle: lifecycle)).lifecycle == .seen)
        }
        #expect(LifecycleRules.apply(.turnStarted, to: makeSession(runState: .working, lifecycle: .merged)).lifecycle == .merged)
        var settled = makeSession(runState: .done, lifecycle: .settled)
        settled = SessionReducer.reduce(settled, .userMessage("again"), at: t0 + 5)
        #expect(settled.lifecycle == .seen)
    }

    @Test func idleAfterADayWithoutActivity() {
        let session = makeSession(runState: .done, lifecycle: .merged)
        let justBefore = LifecycleRules.apply(.tick, to: session, at: t0.addingTimeInterval(LifecycleRules.idleAfter - 1))
        #expect(justBefore.lifecycle == .merged)
        let after = LifecycleRules.apply(.tick, to: session, at: t0.addingTimeInterval(LifecycleRules.idleAfter))
        #expect(after.lifecycle == .idle)
    }

    @Test func cleanupArchives() {
        let session = LifecycleRules.apply(.cleanupConfirmed, to: makeSession(lifecycle: .idle))
        #expect(session.lifecycle == .archived)
    }

    @Test(arguments: [LifecycleEvent.turnEnded, .turnStarted, .dwelled, .movedOn, .settled, .pullRequestMerged, .tick, .unsettled])
    func archivedIsFinal(_ event: LifecycleEvent) {
        let session = makeSession(lifecycle: .archived)
        let applied = LifecycleRules.apply(event, to: session, at: t0.addingTimeInterval(10 * LifecycleRules.idleAfter))
        #expect(applied == session)
    }

    // MARK: Presentation

    @Test(arguments: [
        (Lifecycle.unseen, TilePresentation.full),
        (.seen, .full),
        (.kept, .full),
        (.settled, .pebble),
        (.merged, .pebble),
        (.idle, .faded),
        (.archived, .hidden),
    ])
    func doneSessionsRecedeWithTheirLifecycle(_ lifecycle: Lifecycle, _ expected: TilePresentation) {
        #expect(LifecycleRules.presentation(of: makeSession(runState: .done, lifecycle: lifecycle)) == expected)
    }

    @Test func interruptedSessionsRecedeLikeDoneOnes() {
        #expect(LifecycleRules.presentation(of: makeSession(runState: .interrupted, lifecycle: .seen)) == .full)
    }

    @Test(arguments: [RunState.blocked, .failed(.turnError), .failed(.reportedFailure)])
    func blockedAndFailedNeverRecede(_ state: RunState) {
        for lifecycle in [Lifecycle.unseen, .seen, .kept, .settled, .merged, .idle] {
            #expect(LifecycleRules.presentation(of: makeSession(runState: state, lifecycle: lifecycle)) == .full)
        }
    }

    @Test(arguments: [RunState.working, .preparing(.worktree)])
    func liveSessionsDrawFull(_ state: RunState) {
        #expect(LifecycleRules.presentation(of: makeSession(runState: state, lifecycle: .seen)) == .full)
    }
}
