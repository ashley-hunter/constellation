import Foundation
import Testing
@testable import ConstellationCore

@Suite struct CleanupCandidatesTests {
    private let day = 86_400.0
    private let clean = WorktreeFacts(hasUncommittedChanges: false, hasUnpushedCommits: false, isMerged: true, sizeInBytes: 1_000)

    private func candidates(
        _ sessions: [Session],
        facts: [UUID: WorktreeFacts]? = nil,
        threshold: CleanupThreshold = .default,
        now: Date? = nil
    ) -> [CleanupCandidate] {
        CleanupCandidates.candidates(
            sessions: sessions,
            facts: facts ?? Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, clean) }),
            threshold: threshold,
            now: now ?? t0.addingTimeInterval(2 * day)
        )
    }

    @Test(arguments: [Lifecycle.merged, .idle])
    func mergedAndIdleDoneSessionsAreEligible(_ lifecycle: Lifecycle) {
        let session = makeSession(runState: .done, lifecycle: lifecycle)
        #expect(candidates([session]) == [CleanupCandidate(sessionID: session.id, isTicked: true, warnings: [], bytesFreed: 1_000)])
    }

    @Test(arguments: [Lifecycle.unseen, .seen, .archived])
    func otherLifecyclesAreNot(_ lifecycle: Lifecycle) {
        #expect(candidates([makeSession(runState: .done, lifecycle: lifecycle)]).isEmpty)
    }

    @Test(arguments: [RunState.working, .blocked, .failed(.turnError), .interrupted, .preparing(.fetch)])
    func onlyDoneSessionsAreEligible(_ state: RunState) {
        #expect(candidates([makeSession(runState: state, lifecycle: .idle)]).isEmpty)
    }

    @Test(arguments: [
        (CleanupThreshold.oneDay, 1.5, true),
        (.oneDay, 0.5, false),
        (.threeDays, 2.0, false),
        (.threeDays, 3.5, true),
        (.oneWeek, 6.0, false),
        (.oneWeek, 8.0, true),
        (.never, 365.0, false),
    ])
    func theThresholdGatesSuggestions(_ threshold: CleanupThreshold, _ daysIdle: Double, _ eligible: Bool) {
        let session = makeSession(runState: .done, lifecycle: .merged)
        let result = candidates([session], threshold: threshold, now: t0.addingTimeInterval(daysIdle * day))
        #expect(result.isEmpty == !eligible)
    }

    @Test func workAtRiskIsUntickedAndFlagged() {
        let session = makeSession(runState: .done, lifecycle: .idle)
        let risky = WorktreeFacts(hasUncommittedChanges: true, hasUnpushedCommits: true, isMerged: false, sizeInBytes: 5)
        let result = candidates([session], facts: [session.id: risky])
        #expect(result.first?.isTicked == false)
        #expect(result.first?.warnings == [.uncommittedChanges, .unpushedCommits, .neverMerged])
    }

    @Test func aMergedPRCountsAsMergedEvenIfGitDisagrees() {
        var session = makeSession(runState: .done, lifecycle: .idle, pullRequest: 4)
        session.pullRequest?.state = .merged
        let squashed = WorktreeFacts(hasUncommittedChanges: false, hasUnpushedCommits: false, isMerged: false, sizeInBytes: 5)
        #expect(candidates([session], facts: [session.id: squashed]).first?.isTicked == true)
    }

    @Test func aWorktreeWithoutFactsIsNotOffered() {
        #expect(candidates([makeSession(runState: .done, lifecycle: .merged)], facts: [:]).isEmpty)
    }

    @Test func aSessionInTheProjectRootFreesNothing() {
        var session = makeSession(runState: .done, lifecycle: .merged)
        session.usesWorktree = false
        let result = candidates([session], facts: [:])
        #expect(result == [CleanupCandidate(sessionID: session.id, isTicked: true, warnings: [], bytesFreed: 0)])
    }

    @Test func anIdleSessionInTheProjectRootIsNotFlaggedUnmerged() {
        var session = makeSession(runState: .done, lifecycle: .idle)
        session.usesWorktree = false
        #expect(candidates([session], facts: [:]).first?.warnings == [])
    }

    @Test func oldestComeFirst() {
        var older = makeSession(runState: .done, lifecycle: .idle)
        older.lastActivityAt = t0 - day
        let newer = makeSession(runState: .done, lifecycle: .merged)
        #expect(candidates([newer, older]).map(\.sessionID) == [older.id, newer.id])
    }
}
