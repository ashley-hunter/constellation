import ConstellationCore
import ConstellationGit
import Foundation

enum GitAction: String, Hashable, CaseIterable {
    case commit, push, pullRequest, merge

    var title: String {
        switch self {
        case .commit: "Commit…"
        case .push: "Push"
        case .pullRequest: "Create PR…"
        case .merge: "Merge…"
        }
    }

    /// Merge names the branch it lands on.
    func title(for session: Session) -> String {
        self == .merge ? "Merge into \(session.baseBranch)…" : title
    }

    var systemImage: String {
        switch self {
        case .commit: "checkmark.circle"
        case .push: "arrow.up.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .merge: "arrow.triangle.merge"
        }
    }
}

/// What the commit sheet starts from.
struct CommitPreparation {
    var changes: [WorkingChange]
    var message: String
}

/// What the PR sheet starts from. The branch is pushed first when `push.needsPush`.
struct PullRequestPreparation {
    var push: PushState
    var draft: PullRequestDraft
}

/// Commit, push, Create PR and Merge from the session view header and the tile menu. Each runs in the
/// session's worktree; errors come back to the sheet as text.
extension AppModel {
    func openGitSheet(_ action: GitAction, for id: UUID) {
        guard sessionsByID[id] != nil else { return }
        sheet = .git(action, id)
    }

    func prepareCommit(for id: UUID) async throws -> CommitPreparation {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        let changes = try await services.git.workingChanges(in: session.worktreePath)
        return CommitPreparation(changes: changes, message: PublishText.commitMessage(title: session.title, outcome: session.outcome?.summary))
    }

    /// Returns the new commit's short hash.
    func commit(_ changes: [WorkingChange], message: String, for id: UUID) async throws -> String {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        return try await services.git.commit(changes, message: message, in: session.worktreePath)
    }

    func pushState(for id: UUID) async throws -> PushState {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        return try await services.git.pushState(of: session.worktreePath, base: baseBranch(of: session))
    }

    func push(_ id: UUID) async throws {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        let state = try await pushState(for: id)
        guard state.hasOrigin else { throw GitActionError.noOrigin }
        guard let branch = state.branch else { throw GitActionError.detachedHead }
        try await services.git.push(branch: branch, in: session.worktreePath)
        trackPullRequest(for: id)
        refreshPullRequest(for: session)
    }

    func preparePullRequest(for id: UUID) async throws -> PullRequestPreparation {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        let base = baseBranch(of: session)
        let push = try await pushState(for: id)
        let stat = (try? await services.git.diffStat(in: session.worktreePath, against: base)) ?? ""
        let body = PublishText.pullRequestBody(outcomes: await outcomeSummaries(for: id), diffStat: stat)
        let draft = PullRequestDraft(title: PublishText.pullRequestTitle(session.title), body: body, base: base, head: push.branch ?? session.branch)
        return PullRequestPreparation(push: push, draft: draft)
    }

    /// Pushes the branch if it needs it, then runs `gh pr create`. The footer picks the PR up on the
    /// next status refresh, which this asks for straight away.
    func createPullRequest(_ draft: PullRequestDraft, for id: UUID) async throws -> URL {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        guard let gh = GitService.locateGH() else { throw GitActionError.noGH }
        let state = try await pushState(for: id)
        if state.needsPush { try await push(id) }
        let url = try await services.git.createPullRequest(draft, in: session.worktreePath, gh: gh)
        trackPullRequest(for: id)
        refreshPullRequest(for: session)
        return url
    }

    func mergePreview(for id: UUID) async throws -> MergePreview {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        return try await services.git.mergePreview(of: session.worktreePath, into: baseBranch(of: session))
    }

    /// Lands the branch on its base, then marks the session merged, as a merged PR would, so Clean
    /// up merged work offers it.
    func merge(_ preview: MergePreview, for id: UUID) async throws {
        guard let session = sessionsByID[id] else { throw GitActionError.sessionGone }
        guard let branch = preview.branch else { throw GitActionError.detachedHead }
        try await services.git.merge(branch, into: preview.base, in: session.worktreePath)
        updateLifecycle(id, .pullRequestMerged)
        notice = "Merged into \(preview.base)"
    }

    /// Hands the conflicts back to the agent, through the same path as a typed message.
    func askToRebase(_ id: UUID, onto base: String, conflicts: [String]) {
        let files = ListFormatter.localizedString(byJoining: conflicts)
        sendMessage(UserMessage(text: "Rebase this branch onto \(base) and resolve the conflicts in \(files), then run the tests."), to: id)
    }

    private func baseBranch(of session: Session) -> String {
        session.usesWorktree ? session.baseBranch : project(session.projectID)?.defaultBranch ?? session.baseBranch
    }

    /// Every Outcome the session reported, oldest first, from its stored events.
    private func outcomeSummaries(for id: UUID) async -> [String] {
        let (store, recorder) = (services.store, services.recorder)
        try? await recorder.flush()
        let events = await Task.detached { (try? store.events(for: id)) ?? [] }.value
        let summaries = events.compactMap { stored -> String? in
            if case .outcome(let outcome) = stored.event { return outcome.summary }
            return nil
        }
        if summaries.isEmpty, let last = sessionsByID[id]?.outcome?.summary { return [last] }
        return summaries
    }
}

enum GitActionError: LocalizedError {
    case sessionGone, noOrigin, detachedHead, noGH

    var errorDescription: String? {
        switch self {
        case .sessionGone: "The session is gone."
        case .noOrigin: "This repository has no remote called origin."
        case .detachedHead: "HEAD is detached, so there is no branch to push."
        case .noGH: "Install the GitHub CLI (gh) and run gh auth login to create pull requests."
        }
    }
}

extension Error {
    /// The text a git sheet shows for a failed action.
    var gitActionMessage: String {
        if let error = self as? GitError { return error.message }
        if let error = self as? PublishError { return error.message }
        if let error = self as? MergeError { return error.message }
        return localizedDescription
    }
}
