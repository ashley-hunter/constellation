import ConstellationCore
import Foundation
import Synchronization
import Testing
@testable import ConstellationGitHub

private let cli = GitHubRepository(owner: "cli", name: "cli")

private func pullRequest(_ number: Int, state: PullRequestInfo.State = .open) -> PullRequestInfo {
    PullRequestInfo(number: number, url: URL(string: "https://github.com/cli/cli/pull/\(number)")!, state: state)
}

@Suite struct PollerTests {
    /// A fetch whose answers the test controls, recording each call's branches.
    final class FakeGitHub: Sendable {
        let answers = Mutex<Result<[String: PullRequestInfo], GitHubError>>(.success([:]))
        let calls = Mutex<[[String]]>([])

        func fetch(_ repository: GitHubRepository, _ branches: [String]) throws -> [String: PullRequestInfo] {
            calls.withLock { $0.append(branches) }
            return try answers.withLock { try $0.get() }
        }

        var callCount: Int { calls.withLock { $0.count } }
    }

    private func makePoller(_ fake: FakeGitHub) -> PullRequestPoller {
        PullRequestPoller { try fake.fetch($0, $1) }
    }

    @Test func emitsChangesAndWaitsForEachBranchInterval() async {
        let fake = FakeGitHub()
        let poller = makePoller(fake)
        var updates = poller.updates.makeAsyncIterator()

        fake.answers.withLock { $0 = .success(["feat/a": pullRequest(7)]) }
        await poller.track(repository: cli, branch: "feat/a")
        await poller.track(repository: cli, branch: "feat/b")
        let start = ContinuousClock.now
        await poller.pollDue(at: start)

        #expect(fake.calls.withLock { $0 } == [["feat/a", "feat/b"]])
        #expect(await updates.next() == PullRequestUpdate(repository: cli, branch: "feat/a", pullRequest: pullRequest(7)))

        // Open PR every 30s, no PR every 60s.
        await poller.pollDue(at: start + .seconds(20))
        #expect(fake.callCount == 1)
        await poller.pollDue(at: start + .seconds(31))
        #expect(fake.calls.withLock { $0.last } == ["feat/a"])

        // Unchanged results emit nothing, so the next update is the merge.
        fake.answers.withLock { $0 = .success(["feat/a": pullRequest(7, state: .merged)]) }
        await poller.pollDue(at: start + .seconds(62))
        #expect(fake.calls.withLock { $0.last } == ["feat/a", "feat/b"])
        #expect(await updates.next() == PullRequestUpdate(repository: cli, branch: "feat/a", pullRequest: pullRequest(7, state: .merged)))

        // A PR that disappears is reported as nil.
        fake.answers.withLock { $0 = .success([:]) }
        await poller.refresh(repository: cli, at: start + .seconds(63))
        #expect(await updates.next() == PullRequestUpdate(repository: cli, branch: "feat/a", pullRequest: nil))
    }

    @Test func backsOffAfterFailuresUntilRefreshed() async {
        let fake = FakeGitHub()
        let poller = makePoller(fake)
        fake.answers.withLock { $0 = .failure(.noToken) }

        await poller.track(repository: cli, branch: "feat/a")
        let start = ContinuousClock.now
        await poller.pollDue(at: start)
        await poller.pollDue(at: start + .seconds(120))
        #expect(fake.callCount == 1)
        await poller.pollDue(at: start + .seconds(301))
        #expect(fake.callCount == 2)

        // A refresh (say after a push) skips the back-off.
        await poller.refresh(repository: cli, at: start + .seconds(302))
        #expect(fake.callCount == 3)
    }

    @Test func untrackedBranchesStopPolling() async {
        let fake = FakeGitHub()
        let poller = makePoller(fake)
        await poller.track(repository: cli, branch: "feat/a")
        await poller.untrack(repository: cli, branch: "feat/a")
        await poller.pollDue(at: .now + .seconds(1))
        await poller.refresh(repository: cli)
        #expect(fake.callCount == 0)
    }

    @Test func idleSessionsPollSlowlyUntilActiveAgain() async {
        let fake = FakeGitHub()
        let poller = makePoller(fake)
        await poller.track(repository: cli, branch: "feat/a", sessionIsIdle: true)
        let start = ContinuousClock.now
        await poller.pollDue(at: start)
        await poller.pollDue(at: start + .seconds(120))
        #expect(fake.callCount == 1)

        await poller.track(repository: cli, branch: "feat/a", sessionIsIdle: false)
        await poller.pollDue(at: start + .seconds(121))
        #expect(fake.callCount == 2)
    }

    @Test func backOffGrowsForTransientErrors() {
        #expect(PullRequestPoller.backOff(after: URLError(.notConnectedToInternet), failures: 1) == .seconds(30))
        #expect(PullRequestPoller.backOff(after: URLError(.timedOut), failures: 3) == .seconds(120))
        #expect(PullRequestPoller.backOff(after: URLError(.timedOut), failures: 9) == .seconds(300))
        #expect(PullRequestPoller.backOff(after: GitHubError.rateLimited(retryAfter: .seconds(42)), failures: 1) == .seconds(42))
        #expect(PullRequestPoller.backOff(after: GitHubError.repositoryNotFound, failures: 1) == .seconds(1800))
    }
}
