import Foundation

public struct Session: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var host: Host
    public var provider: Provider
    public var model: String
    public var permissionMode: PermissionMode
    /// Reasoning effort for the next turn, nil for the provider's default.
    public var effort: String?
    public var fastMode: Bool
    public var title: String
    /// The worktree, or the project root when the session runs without one.
    public var worktreePath: URL
    public var usesWorktree: Bool
    public var branch: String
    public var baseBranch: String
    /// Claude Code's session id or Codex's thread id.
    public var nativeID: String?

    public var createdAt: Date
    public var lastActivityAt: Date
    public var lastSeenAt: Date?
    /// When the current or last turn started: the prompt reaching the provider, or a retried launch.
    /// Not stored, so a restored session has neither this nor `turnEndedAt`.
    public var turnStartedAt: Date?
    public var turnEndedAt: Date?

    public var runState: RunState
    /// What went wrong, set only while `runState` is failed.
    public var failureMessage: String?
    public var lifecycle: Lifecycle
    /// Pending asks in the order they were raised.
    public var asks: [Ask]
    public var outcome: Outcome?
    public var pullRequest: PullRequestInfo?
    public var filesTouched: Set<String>

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        host: Host = .thisMac,
        provider: Provider,
        model: String,
        permissionMode: PermissionMode = .default,
        title: String,
        worktreePath: URL,
        usesWorktree: Bool = true,
        branch: String,
        baseBranch: String,
        nativeID: String? = nil,
        createdAt: Date = .now,
        runState: RunState = .preparing(.fetch),
        lifecycle: Lifecycle = .unseen
    ) {
        self.id = id
        self.projectID = projectID
        self.host = host
        self.provider = provider
        self.model = model
        self.permissionMode = permissionMode
        self.effort = nil
        self.fastMode = false
        self.title = title
        self.worktreePath = worktreePath
        self.usesWorktree = usesWorktree
        self.branch = branch
        self.baseBranch = baseBranch
        self.nativeID = nativeID
        self.createdAt = createdAt
        self.lastActivityAt = createdAt
        self.lastSeenAt = nil
        self.runState = runState
        self.failureMessage = nil
        self.lifecycle = lifecycle
        self.asks = []
        self.outcome = nil
        self.pullRequest = nil
        self.filesTouched = []
    }

    /// Pending asks, oldest first. They are answered in this order.
    public var pendingAsks: [Ask] { asks.filter { $0.status == .pending } }

    public var isDraft: Bool { runState == .draft }

    /// The ask to answer next.
    public var nextAsk: Ask? { asks.first { $0.status == .pending } }

    /// The branch as a tile's footer shows it: without a leading `<user>/` or `constellation/`, or
    /// nil when there's none or it's the project's default branch.
    public func shortBranch(defaultBranch: String?) -> String? {
        Self.shortBranch(branch, defaultBranch: defaultBranch)
    }

    public static func shortBranch(_ branch: String, defaultBranch: String?) -> String? {
        guard !branch.isEmpty, branch != defaultBranch else { return nil }
        var parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 1, parts[0] != "constellation" { parts.removeFirst() }
        if parts.count > 1, parts[0] == "constellation" { parts.removeFirst() }
        return parts.joined(separator: "/")
    }

    /// The branch as a pile's label shows it after the project's name: the short branch without
    /// the request words a generated name starts with, so "constellation/add-a-get-products-id"
    /// reads "get-products-id".
    public static func labelBranch(_ branch: String, defaultBranch: String?) -> String? {
        guard let short = shortBranch(branch, defaultBranch: defaultBranch) else { return nil }
        var words = short.split(separator: "-", omittingEmptySubsequences: false)
        while words.count > 2, branchFiller.contains(words[0].lowercased()) { words.removeFirst() }
        // All request words, as an older name like "please-can-you-add-a" is: nothing worth showing.
        if words.allSatisfy({ branchFiller.contains($0.lowercased()) }) { return nil }
        return words.joined(separator: "-")
    }

    private static let branchFiller: Set<String> = ["add", "a", "an", "the", "please", "can", "could", "you", "i", "want", "to", "create", "implement", "new"]

    /// How long the current turn has run (from launch while preparing), or how long the last one
    /// took once it is done or failed. Nil when that isn't known.
    public func elapsed(at now: Date) -> TimeInterval? {
        switch runState {
        case .preparing:
            now.timeIntervalSince(turnStartedAt ?? createdAt)
        case .working, .blocked:
            turnStartedAt.map { now.timeIntervalSince($0) }
        case .done, .failed:
            turnStartedAt.flatMap { start in turnEndedAt.map { $0.timeIntervalSince(start) } }
        case .draft, .interrupted:
            nil
        }
    }
}

/// A short elapsed time for a tile footer: "12s", "4m", "1h 5m", "2d". Rounds down.
public enum ElapsedTime {
    public static func label(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400:
            let (hours, minutes) = (seconds / 3_600, seconds % 3_600 / 60)
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        default: return "\(seconds / 86_400)d"
        }
    }
}

public enum RunState: Hashable, Codable, Sendable {
    /// Not launched yet: a new session you are still writing the first message for. Nothing is on
    /// disk and no process runs until it is sent.
    case draft
    case preparing(LaunchStage)
    case working
    case blocked
    case failed(FailureReason)
    case done
    case interrupted
}

extension RunState {
    /// Working or blocked: a turn the provider is running. Blocked can briefly have no pending ask,
    /// when the provider reports it before the ask arrives.
    public var isTurnRunning: Bool {
        self == .working || self == .blocked
    }

    /// Done or failed: the last turn has finished and its result is in.
    public var hasEndedTurn: Bool {
        switch self {
        case .done, .failed: true
        case .draft, .preparing, .working, .blocked, .interrupted: false
        }
    }
}

/// The staged launch, in order. A failure records the stage it happened in.
public enum LaunchStage: String, CaseIterable, Hashable, Codable, Sendable {
    case fetch, worktree, setup, starting
}

public enum FailureReason: Hashable, Codable, Sendable {
    case turnError
    case processExited
    case auth
    case usageLimit
    case reportedFailure
    case launch(LaunchStage)
}

public enum Lifecycle: String, CaseIterable, Hashable, Codable, Sendable {
    case unseen, seen
    /// Seen, then brought back out of the Settled tray by hand: stays on its worktree's pile and
    /// doesn't settle by itself until its next turn.
    case kept
    /// Seen and put away, after you moved on from it or by hand: in the Settled tray.
    case settled
    case merged, idle, archived
}

public struct Outcome: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable {
        case succeeded, failed
    }

    public var status: Status
    public var summary: String

    public init(status: Status, summary: String) {
        self.status = status
        self.summary = summary
    }
}

public struct PullRequestInfo: Hashable, Codable, Sendable {
    public enum State: String, Hashable, Codable, Sendable {
        case open, merged, closed
    }

    public enum ReviewDecision: String, Hashable, Codable, Sendable {
        case approved, changesRequested, reviewRequired
    }

    public var number: Int
    public var url: URL
    public var state: State
    public var isDraft: Bool
    public var reviewDecision: ReviewDecision?
    public var mergedAt: Date?
    public var checks: CheckSummary?

    public init(
        number: Int,
        url: URL,
        state: State,
        isDraft: Bool = false,
        reviewDecision: ReviewDecision? = nil,
        mergedAt: Date? = nil,
        checks: CheckSummary? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergedAt = mergedAt
        self.checks = checks
    }
}

/// The head commit's status check rollup.
public struct CheckSummary: Hashable, Codable, Sendable {
    public enum State: String, Hashable, Codable, Sendable {
        case pending, success, failure, error, expected
    }

    public var state: State
    public var passed: Int
    public var total: Int

    public init(state: State, passed: Int, total: Int) {
        self.state = state
        self.passed = passed
        self.total = total
    }
}

extension Session {
    /// Its open PR has failing checks or changes requested, and the agent isn't on it: it needs you.
    public var pullRequestNeedsYou: Bool {
        guard [.done, .interrupted].contains(runState), let pullRequest, pullRequest.state == .open else { return false }
        let failing = pullRequest.checks.map { $0.state == .failure || $0.state == .error } ?? false
        return failing || pullRequest.reviewDecision == .changesRequested
    }
}
