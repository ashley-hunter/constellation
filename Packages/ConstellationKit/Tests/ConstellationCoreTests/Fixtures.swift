import Foundation
@testable import ConstellationCore

let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
let projectA = UUID()
let projectB = UUID()

func makeSession(
    project: UUID = projectA,
    title: String = "Session",
    worktree: String = "/wt/\(UUID().uuidString.prefix(8))",
    baseBranch: String = "main",
    createdAt: Date = t0,
    runState: RunState = .working,
    lifecycle: Lifecycle = .unseen,
    files: Set<String> = [],
    pullRequest: Int? = nil
) -> Session {
    var session = Session(
        projectID: project,
        provider: .claudeCode,
        model: "opus",
        title: title,
        worktreePath: URL(filePath: worktree),
        branch: "constellation/\(UUID().uuidString.prefix(8).lowercased())",
        baseBranch: baseBranch,
        createdAt: createdAt,
        runState: runState,
        lifecycle: lifecycle
    )
    session.filesTouched = files
    if let pullRequest {
        session.pullRequest = PullRequestInfo(
            number: pullRequest,
            url: URL(string: "https://github.com/a/b/pull/\(pullRequest)")!,
            state: .open
        )
    }
    return session
}

func permissionAsk(_ id: String, session: Session, at date: Date = t0) -> Ask {
    Ask(
        id: id,
        sessionID: session.id,
        kind: .permission(PermissionAsk(toolName: "Bash", summary: "rm -rf build")),
        createdAt: date
    )
}

extension Session {
    func reducing(_ events: SessionEvent..., at now: Date = t0) -> Session {
        events.reduce(self) { SessionReducer.reduce($0, $1, at: now) }
    }
}
