import ConstellationCore
import AppKit
import ConstellationGit
import Foundation

/// Adding projects, from the folder browser or a folder dropped on the desktop.
extension AppModel {
    /// Accepts a git repository as a project. A folder inside a repo adds the repo's root. `then`
    /// gets the project, new or already known.
    func addProject(at folder: URL, then: ((Project) -> Void)? = nil) {
        Task { [weak self] in
            do {
                if let project = try await self?.addProject(at: folder, quietly: then != nil) { then?(project) }
            } catch {
                self?.notice = "\(folder.lastPathComponent) isn't a git repository."
            }
        }
    }

    /// Throws when the folder isn't in a git repository.
    func addProject(at folder: URL, quietly: Bool) async throws -> Project {
        let repository = try await services.git.inspectProject(at: folder)
        return register(repository, quietly: quietly)
    }

    @discardableResult
    func register(_ repository: ProjectRepository, quietly: Bool = false) -> Project {
        let root = repository.root.standardizedFileURL
        if let existing = projects.first(where: { $0.rootPath.standardizedFileURL == root }) {
            projectFilter = nil
            if !quietly { notice = "\(existing.name) is already a project." }
            return existing
        }
        let project = Project(
            name: repository.name,
            rootPath: root,
            swatch: ProjectSwatch.next(after: projects.map(\.swatch)),
            defaultBranch: repository.defaultBranch
        )
        replaceProjects(projects + [project])
        let store = services.store
        Task.detached { try? store.save(project) }
        return project
    }
}

/// Removing a project: Constellation forgets it, its sessions and its terminals. The repo stays, and
/// so do the worktrees its sessions made unless you tick the box to delete them too.
extension AppModel {
    func confirmRemoveProject(_ id: UUID) {
        guard let project = project(id) else { return }
        let sessions = sessionsByID.values.filter { $0.projectID == id }
        let worktrees = sessions.filter { $0.usesWorktree && FileManager.default.fileExists(atPath: $0.worktreePath.path(percentEncoded: false)) }
        let terminals = terminalsByID.values.filter { $0.projectID == id }.count
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(project.name)\u{201D}?"
        let running = sessions.filter { processPhase($0.id) == .live }.count
        let items = [Self.count(sessions.count, "session"), terminals > 0 ? Self.count(terminals, "terminal") : nil].compactMap(\.self)
        alert.informativeText = [
            "Its \(items.joined(separator: " and ")) leave Constellation, archived ones too.",
            running > 0 ? "\(Self.count(running, "running session")) will be stopped." : nil,
            "The repository folder stays as it is.",
            worktrees.isEmpty ? nil : "A worktree with uncommitted changes is kept either way.",
        ].compactMap(\.self).joined(separator: " ")
        if !worktrees.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = worktrees.count == 1 ? "Also delete its worktree" : "Also delete its \(worktrees.count) worktrees"
            alert.suppressionButton?.state = .off
        }
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let deletesWorktrees = alert.suppressionButton?.state == .on
        Task { await removeProject(id, deletingWorktrees: deletesWorktrees ? worktrees.map(\.id) : []) }
    }

    func removeProject(_ id: UUID, deletingWorktrees: [UUID]) async {
        guard let project = project(id) else { return }
        // Archiving removes a worktree the way closing a session does, and stops its process.
        let problems = await archive(deletingWorktrees, deletesBranches: false)
        for session in sessionsByID.values where session.projectID == id {
            stop(session.id)
            if focusedItem == .session(session.id) { focusedItem = nil }
            if openedSessionID == session.id { openedSessionID = nil }
            sessionsByID[session.id] = nil
            if let repository = repositories[id] {
                let (poller, branch) = (services.pullRequests, session.branch)
                Task { await poller.untrack(repository: repository, branch: branch) }
            }
        }
        for terminal in terminalsByID.values where terminal.projectID == id { closeTerminal(terminal.id) }
        if projectFilter == id { projectFilter = nil }
        repositories[id] = nil
        replaceProjects(projects.filter { $0.id != id })
        let (store, secrets) = (services.store, services.secrets)
        let removed = await Task.detached {
            let sessionIDs = (try? store.sessionIDs(inProject: id)) ?? []
            for sessionID in sessionIDs { try? secrets.deleteAll(scope: .session(sessionID)) }
            try? secrets.deleteAll(scope: .project(id))
            return (try? store.deleteProject(id)) != nil
        }.value
        notice = ([removed ? "Removed \(project.name)." : "Removed \(project.name), but the store couldn't forget it."] + problems).joined(separator: " ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// What the palette's Add project flow is showing: its two choices, or one of them.
enum ProjectFlow: Hashable {
    case menu, newProject, openFolder
}

extension AppModel {
    func presentProjectFlow(_ flow: ProjectFlow) {
        sheet = .projects(flow)
    }

    /// Where New project makes folders: the setting, else next to the latest project, else ~/code
    /// when it exists, else home.
    var newProjectsRoot: URL {
        if let folder = settings.newProjectsFolder { return folder }
        if let parent = latestProjectParent { return parent }
        let code = URL.homeDirectory.appending(path: "code", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: code.path(percentEncoded: false)) ? code : URL.homeDirectory
    }

    /// Where Open folder starts: next to the latest project, else home.
    var openFolderStart: URL {
        latestProjectParent ?? URL.homeDirectory
    }

    private var latestProjectParent: URL? {
        guard let parent = projects.last?.rootPath.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) else { return nil }
        return parent
    }

    /// Adds the repository holding `folder` and opens a draft in it. Returns what to show inline
    /// when that fails.
    func openProject(at folder: URL) async -> String? {
        do {
            let project = try await addProject(at: folder, quietly: true)
            newDraft(in: project.id)
            return nil
        } catch {
            return "\(folder.lastPathComponent) isn't a git repository."
        }
    }

    /// Makes `folder` a new repository with an empty initial commit, adds it as a project and opens
    /// a draft in it. Returns what to show inline when that fails.
    func createProject(at folder: URL) async -> String? {
        do {
            let repository = try await services.git.createRepository(at: folder)
            newDraft(in: register(repository, quietly: true).id)
            return nil
        } catch let error as GitError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// The repository `folder` sits in, if any.
    func enclosingRepository(of folder: URL) async -> URL? {
        try? await services.git.repositoryRoot(containing: folder)
    }
}

extension ProjectFlow {
    /// The step a palette action opens, for the actions that open one.
    init?(_ action: ActionID) {
        switch action {
        case .projectAdd: self = .menu
        case .projectNew: self = .newProject
        default: return nil
        }
    }
}
