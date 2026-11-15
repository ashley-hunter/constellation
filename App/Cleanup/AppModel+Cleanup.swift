import ConstellationCore
import ConstellationGit
import Foundation

/// What clean-up learned from git about one session's worktree.
struct WorktreeInspection: Sendable {
    var facts: WorktreeFacts
    var dirtyFileCount: Int
    var worktreeExists: Bool
}

enum CleanupSettingKey {
    static let threshold = "cleanupThreshold"
    static let deletesBranches = "cleanupDeletesBranches"
}

/// Clean up merged work: inspecting worktrees, then archiving what you tick.
extension AppModel {
    /// Done sessions that are merged or idle, whatever the threshold.
    var recededDoneSessions: [Session] {
        sessionsByID.values.filter { $0.runState == .done && ($0.lifecycle == .merged || $0.lifecycle == .idle) }
    }

    var cleanupThreshold: CleanupThreshold {
        get { settings.cleanupThreshold }
        set { settings.cleanupThreshold = newValue }
    }

    var cleanupDeletesBranches: Bool {
        get { setting(CleanupSettingKey.deletesBranches) != "false" }
        set { saveSetting(CleanupSettingKey.deletesBranches, newValue ? "true" : "false") }
    }

    private func setting(_ key: String) -> String? {
        (try? services.store.setting(key)) ?? nil
    }

    /// Git status and disk size for each worktree session, checked in parallel.
    func inspectWorktrees(of sessions: [Session]) async -> [UUID: WorktreeInspection] {
        let git = services.git
        let projects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return await withTaskGroup(of: (UUID, WorktreeInspection?).self) { group in
            for session in sessions where session.usesWorktree {
                guard let project = projects[session.projectID] else { continue }
                group.addTask {
                    (session.id, await Self.inspect(session, in: project, git: git))
                }
            }
            var inspections: [UUID: WorktreeInspection] = [:]
            for await (id, inspection) in group {
                inspections[id] = inspection
            }
            return inspections
        }
    }

    private nonisolated static func inspect(_ session: Session, in project: Project, git: GitService) async -> WorktreeInspection? {
        let path = session.worktreePath
        if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
            guard let status = try? await git.status(of: path, defaultBranch: project.defaultBranch) else { return nil }
            let size = await git.diskSize(of: path)
            return WorktreeInspection(facts: WorktreeFacts(status: status, sizeInBytes: size), dirtyFileCount: status.dirtyFileCount, worktreeExists: true)
        }
        // The folder is gone already, so only the branch can still hold work.
        let merged = (try? await git.isMerged(session.branch, into: project.defaultBranch, projectRoot: project.rootPath)) ?? false
        let pushed = (try? await git.isPushed(session.branch, projectRoot: project.rootPath)) ?? false
        let facts = WorktreeFacts(hasUncommittedChanges: false, hasUnpushedCommits: !merged && !pushed, isMerged: merged, sizeInBytes: 0)
        return WorktreeInspection(facts: facts, dirtyFileCount: 0, worktreeExists: false)
    }

    /// Removes each session's worktree, its branch when safe and wanted, and its caches, deletes its
    /// secrets, then archives it. Removal is never forced, so work that appeared after the sheet's
    /// inspection is safe: a worktree git refuses to remove keeps its session on the desktop.
    /// Returns a message per session that was kept.
    func archive(_ ids: [UUID], deletesBranches: Bool) async -> [String] {
        var problems: [String] = []
        for id in ids {
            guard let session = sessionsByID[id], let project = project(session.projectID) else { continue }
            stop(id)
            await services.git.deleteCheckpoints(session: id, in: project.rootPath)
            if session.usesWorktree {
                let worktree = Worktree(path: session.worktreePath, branch: session.branch, baseBranch: session.baseBranch)
                do {
                    try await services.git.cleanUp(
                        worktree,
                        defaultBranch: project.defaultBranch,
                        projectRoot: project.rootPath,
                        force: false,
                        deleteBranch: deletesBranches
                    )
                } catch {
                    Log.app.error("Clean-up of \(session.title, privacy: .public) failed: \(error, privacy: .public)")
                    if FileManager.default.fileExists(atPath: session.worktreePath.path(percentEncoded: false)) {
                        problems.append("Kept \(session.title): git wouldn't remove its worktree.")
                        continue
                    }
                }
                // The folder is gone, so its name goes with it.
                forgetWorktreeName(Piles.folder(session.worktreePath))
            }
            let secrets = services.secrets
            let deleted = await Task.detached { (try? secrets.deleteAll(scope: .session(id))) != nil }.value
            if !deleted {
                problems.append("Archived \(session.title), but its secrets are still in the Keychain.")
            }
            finishArchiving(id)
        }
        return problems
    }

    /// Archived sessions leave the desktop and memory; the store keeps them for search.
    private func finishArchiving(_ id: UUID) {
        guard let session = sessionsByID[id] else { return }
        let archived = LifecycleRules.apply(.cleanupConfirmed, to: session)
        if focusedItem == .session(id) { focusedItem = nil }
        if openedSessionID == id { openedSessionID = nil }
        sessionsByID[id] = nil
        browserHost.close(id)
        do {
            try services.store.save(archived)
        } catch {
            Log.app.error("Saving archived session failed: \(error, privacy: .public)")
        }
        if let repository = repositories[session.projectID] {
            let (poller, branch) = (services.pullRequests, session.branch)
            Task { await poller.untrack(repository: repository, branch: branch) }
        }
    }
}
