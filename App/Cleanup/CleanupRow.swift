import ConstellationCore
import Foundation

/// One clean-up candidate with what its row shows.
struct CleanupRow: Identifiable {
    let candidate: CleanupCandidate
    let session: Session
    let inspection: WorktreeInspection?

    var id: UUID { session.id }
    var isWarned: Bool { !candidate.warnings.isEmpty }
    var deletesBranch: Bool { session.usesWorktree && inspection?.facts.hasUnpushedCommits == false }

    /// e.g. "PR #218 merged 2h ago" or "Never merged, idle 6d".
    func meta(now: Date) -> String {
        if let pullRequest = session.pullRequest, pullRequest.state == .merged {
            return "PR #\(pullRequest.number) merged \(Self.age(since: pullRequest.mergedAt ?? session.lastActivityAt, now: now)) ago"
        }
        let idle = Self.age(since: session.lastActivityAt, now: now)
        if candidate.warnings.contains(.neverMerged) { return "Never merged, idle \(idle)" }
        return session.lifecycle == .merged ? "Merged \(idle) ago" : "Done \(idle) ago"
    }

    /// The worktree path, or what would be lost, or why there is nothing to remove.
    var detail: String {
        var losses: [String] = []
        if let count = inspection?.dirtyFileCount, count > 0 {
            losses.append(count == 1 ? "1 uncommitted file" : "\(count) uncommitted files")
        }
        if candidate.warnings.contains(.unpushedCommits) { losses.append("not pushed") }
        if !losses.isEmpty { return losses.joined(separator: ", ") }
        guard session.usesWorktree else { return "Ran in the main checkout, transcript only" }
        guard inspection?.worktreeExists != false else { return "Worktree already removed" }
        return session.worktreePath.lastPathComponent
    }

    /// The whole worktree path, for the row's tooltip.
    var fullPath: String {
        session.worktreePath.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var detailIsWarning: Bool {
        candidate.warnings.contains(.uncommittedChanges) || candidate.warnings.contains(.unpushedCommits)
    }

    var size: String {
        candidate.bytesFreed > 0 ? Self.bytes(candidate.bytesFreed) : "-"
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func age(since date: Date, now: Date) -> String {
        Duration.seconds(max(60, now.timeIntervalSince(date)))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1))
    }
}

extension CleanupThreshold {
    var title: String {
        switch self {
        case .oneDay: "1 day idle"
        case .threeDays: "3 days idle"
        case .oneWeek: "1 week idle"
        case .never: "Never"
        }
    }

    /// The sheet's subtitle.
    var subtitle: String {
        switch self {
        case .oneDay: "Finished sessions idle for more than a day"
        case .threeDays: "Finished sessions idle for more than 3 days"
        case .oneWeek: "Finished sessions idle for more than a week"
        case .never: "Clean-up suggestions are off"
        }
    }
}
