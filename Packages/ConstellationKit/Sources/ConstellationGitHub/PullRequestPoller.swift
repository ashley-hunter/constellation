import ConstellationCore
import Foundation

/// A change in a tracked branch's PR, or the PR disappearing (nil).
public struct PullRequestUpdate: Hashable, Sendable {
    public var repository: GitHubRepository
    public var branch: String
    public var pullRequest: PullRequestInfo?
}

/// Polls PR status for tracked branches, each at its own adaptive interval, batching due
/// branches of one repository into one query. Emits only changes.
///
/// Failures never surface: a repository that errors is skipped until its back-off passes,
/// so a missing `gh` or a non-GitHub remote just means no updates.
public actor PullRequestPoller {
    public typealias Fetch = @Sendable (GitHubRepository, [String]) async throws -> [String: PullRequestInfo]

    private struct Tracked {
        var sessionIsIdle: Bool
        var pullRequest: PullRequestInfo?
        var due: ContinuousClock.Instant
    }

    public nonisolated let updates: AsyncStream<PullRequestUpdate>
    private let continuation: AsyncStream<PullRequestUpdate>.Continuation
    private let fetch: Fetch
    private let tick: Duration
    private var tracked: [GitHubRepository: [String: Tracked]] = [:]
    private var blockedUntil: [GitHubRepository: ContinuousClock.Instant] = [:]
    private var failures: [GitHubRepository: Int] = [:]
    private var inFlight: Set<GitHubRepository> = []
    private var loop: Task<Void, Never>?

    public init(service: GitHubStatusService = GitHubStatusService(), tick: Duration = .seconds(5)) {
        self.init(tick: tick) { try await service.pullRequests(repository: $0, branches: $1) }
    }

    public init(tick: Duration = .seconds(5), fetch: @escaping Fetch) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.fetch = fetch
        self.tick = tick
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, tick] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollDue(at: .now)
                try? await Task.sleep(for: tick)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Starts watching a branch, or updates whether its session is idle. A new branch is polled on the next tick.
    public func track(repository: GitHubRepository, branch: String, sessionIsIdle: Bool = false) {
        if var existing = tracked[repository]?[branch] {
            if existing.sessionIsIdle && !sessionIsIdle { existing.due = .now }
            existing.sessionIsIdle = sessionIsIdle
            tracked[repository]?[branch] = existing
        } else {
            tracked[repository, default: [:]][branch] = Tracked(sessionIsIdle: sessionIsIdle, due: .now)
        }
    }

    public func untrack(repository: GitHubRepository, branch: String) {
        tracked[repository]?[branch] = nil
        if tracked[repository]?.isEmpty == true {
            tracked[repository] = nil
            blockedUntil[repository] = nil
            failures[repository] = nil
        }
    }

    /// Polls a repository now, for a local push or a turn end. Clears any back-off, since the user may have just fixed auth.
    public func refresh(repository: GitHubRepository, at now: ContinuousClock.Instant = .now) async {
        guard let branches = tracked[repository] else { return }
        blockedUntil[repository] = nil
        await poll(repository, branches: Array(branches.keys), at: now)
    }

    func pollDue(at now: ContinuousClock.Instant) async {
        for (repository, branches) in tracked {
            if let blocked = blockedUntil[repository], blocked > now { continue }
            let due = branches.filter { $0.value.due <= now }.map(\.key)
            if !due.isEmpty { await poll(repository, branches: due, at: now) }
        }
    }

    private func poll(_ repository: GitHubRepository, branches: [String], at now: ContinuousClock.Instant) async {
        guard inFlight.insert(repository).inserted else { return }
        defer { inFlight.remove(repository) }

        let result: [String: PullRequestInfo]
        do {
            result = try await fetch(repository, branches.sorted())
        } catch {
            backOff(repository, after: error, at: now)
            return
        }
        failures[repository] = nil

        for branch in branches {
            // The branch may have been untracked while the request was in flight.
            guard var entry = tracked[repository]?[branch] else { continue }
            let pullRequest = result[branch]
            if pullRequest != entry.pullRequest {
                continuation.yield(PullRequestUpdate(repository: repository, branch: branch, pullRequest: pullRequest))
            }
            entry.pullRequest = pullRequest
            entry.due = now + GitHubStatusService.pollInterval(for: pullRequest, sessionIsIdle: entry.sessionIsIdle)
            tracked[repository]?[branch] = entry
        }
    }

    private func backOff(_ repository: GitHubRepository, after error: any Error, at now: ContinuousClock.Instant) {
        let count = (failures[repository] ?? 0) + 1
        failures[repository] = count
        blockedUntil[repository] = now + Self.backOff(after: error, failures: count)
    }

    static func backOff(after error: any Error, failures: Int) -> Duration {
        switch error as? GitHubError {
        case .rateLimited(let retryAfter): retryAfter
        case .noToken, .unauthorized: .seconds(300)
        case .repositoryNotFound: .seconds(1800)
        default: min(.seconds(30) * (1 << min(failures - 1, 4)), .seconds(300))
        }
    }
}
