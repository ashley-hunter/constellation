import Foundation

public enum CleanupThreshold: String, CaseIterable, Hashable, Codable, Sendable {
    case oneDay, threeDays, oneWeek, never

    public static let `default` = CleanupThreshold.oneDay

    public var interval: TimeInterval? {
        switch self {
        case .oneDay: 86_400
        case .threeDays: 3 * 86_400
        case .oneWeek: 7 * 86_400
        case .never: nil
        }
    }
}

/// What git knows about a session's worktree, gathered before computing candidates.
public struct WorktreeFacts: Hashable, Sendable {
    public var hasUncommittedChanges: Bool
    public var hasUnpushedCommits: Bool
    public var isMerged: Bool
    /// Worktree plus caches, in bytes.
    public var sizeInBytes: Int64

    public init(hasUncommittedChanges: Bool, hasUnpushedCommits: Bool, isMerged: Bool, sizeInBytes: Int64) {
        self.hasUncommittedChanges = hasUncommittedChanges
        self.hasUnpushedCommits = hasUnpushedCommits
        self.isMerged = isMerged
        self.sizeInBytes = sizeInBytes
    }
}

public struct CleanupCandidate: Identifiable, Hashable, Sendable {
    public enum Warning: Hashable, Sendable {
        case uncommittedChanges
        case unpushedCommits
        case neverMerged
    }

    public var sessionID: UUID
    /// Unticked when there is any warning.
    public var isTicked: Bool
    public var warnings: [Warning]
    public var bytesFreed: Int64

    public var id: UUID { sessionID }

    public init(sessionID: UUID, isTicked: Bool, warnings: [Warning], bytesFreed: Int64) {
        self.sessionID = sessionID
        self.isTicked = isTicked
        self.warnings = warnings
        self.bytesFreed = bytesFreed
    }
}

public enum CleanupCandidates {
    /// Merged or idle done sessions that have been inactive longer than the threshold, oldest first.
    ///
    /// A worktree session needs facts from git before it can be offered. A session run in the
    /// project root frees nothing, since clean-up never touches a project root, but can still be archived.
    public static func candidates(
        sessions: [Session],
        facts: [UUID: WorktreeFacts],
        threshold: CleanupThreshold,
        now: Date = .now
    ) -> [CleanupCandidate] {
        guard let interval = threshold.interval else { return [] }
        return sessions
            .filter { isEligible($0) && now.timeIntervalSince($0.lastActivityAt) > interval }
            .sorted { ($0.lastActivityAt, $0.id.uuidString) < ($1.lastActivityAt, $1.id.uuidString) }
            .compactMap { session in
                let facts = facts[session.id]
                if session.usesWorktree, facts == nil { return nil }
                let warnings = warnings(session, facts)
                return CleanupCandidate(
                    sessionID: session.id,
                    isTicked: warnings.isEmpty,
                    warnings: warnings,
                    bytesFreed: session.usesWorktree ? facts?.sizeInBytes ?? 0 : 0
                )
            }
    }

    private static func isEligible(_ session: Session) -> Bool {
        guard session.runState == .done else { return false }
        return session.lifecycle == .merged || session.lifecycle == .idle
    }

    private static func warnings(_ session: Session, _ facts: WorktreeFacts?) -> [CleanupCandidate.Warning] {
        var warnings: [CleanupCandidate.Warning] = []
        if facts?.hasUncommittedChanges == true { warnings.append(.uncommittedChanges) }
        if facts?.hasUnpushedCommits == true { warnings.append(.unpushedCommits) }
        let merged = facts?.isMerged == true
            || session.pullRequest?.state == .merged
            || session.lifecycle == .merged
        // Work in the project root stays there, so only a worktree's branch can be lost unmerged.
        if !merged, session.usesWorktree { warnings.append(.neverMerged) }
        return warnings
    }
}
