import ConstellationCore
import ConstellationGit
import ConstellationMCP
import ConstellationProviders
import Foundation

/// The staged launch: fetch, worktree, setup script, provider. The tile shows each stage, and a
/// failure rolls the worktree back and leaves the tile failed at its stage with a Retry.
extension AppModel {
    func retryLaunch(_ id: UUID) {
        guard let failed = sessionsByID[id], let project = project(failed.projectID) else { return }
        var session = SessionReducer.relaunched(failed)
        session.worktreePath = project.rootPath
        session.branch = ""
        sessionsByID[id] = session
        startLaunch(id, message: lastPrompts[id] ?? UserMessage(text: session.title))
    }

    /// Runs the staged launch for a session whose first message is `message`.
    func startLaunch(_ id: UUID, message: UserMessage) {
        runLaunchTask(id) { await $0.runLaunch(id, message: message) }
    }

    private func runLaunch(_ id: UUID, message: UserMessage) async {
        guard let session = sessionsByID[id], let project = project(session.projectID) else { return }
        let prompt = message.text
        var worktree: Worktree?
        do {
            if session.usesWorktree {
                let prepared = try await prepareWorktree(for: id, project: project, base: session.baseBranch, prompt: prompt)
                worktree = prepared
                update(id) {
                    $0.worktreePath = prepared.path
                    $0.branch = prepared.branch
                    $0.baseBranch = prepared.baseBranch
                }
            } else {
                setStage(.starting, for: id)
                let branch = try await services.git.currentBranch(of: project.rootPath)
                update(id) { $0.branch = branch ?? "detached" }
            }
            try Task.checkCancellation()
            var message = message
            if !message.attachments.isEmpty, let session = sessionsByID[id] {
                message = await Self.staged(message, for: session, git: services.git)
            }
            // A question in the project folder is asked not to change anything, out of the transcript.
            let instructions = questionLaunches.contains(id) ? QuestionPrompt.instruction : nil
            try await startProviderOrThrow(id, message: message, resumeID: nil, instructions: instructions)
        } catch {
            if let worktree {
                let (git, root) = (services.git, project.rootPath)
                await Task.detached { try? await git.discardWorktree(worktree, projectRoot: root) }.value
                update(id) {
                    $0.worktreePath = root
                    $0.branch = ""
                }
            }
            failLaunch(id, error)
        }
    }

    /// Creates the worktree and renames it from the prompt before setup runs, so the setup script and
    /// the provider both see its final path.
    private func prepareWorktree(for id: UUID, project: Project, base: String, prompt: String) async throws -> Worktree {
        let git = services.git
        setStage(.fetch, for: id)
        await git.fetch(project.rootPath)

        setStage(.worktree, for: id)
        try Task.checkCancellation()
        var worktree = try await git.createWorktree(projectRoot: project.rootPath, projectName: project.name, base: base)
        do {
            // From the short title, so the branch reads like the card: "post-products-endpoint".
            let slug = BranchSlug.make(from: SessionTitle.make(from: prompt))
            if !slug.isEmpty, let renamed = try? await git.rename(worktree, projectRoot: project.rootPath, to: slug, moveDirectory: true) {
                worktree = renamed
            }
            if let script = setupScript(for: project, worktree: worktree.path) {
                setStage(.setup, for: id)
                try Task.checkCancellation()
                try await git.runSetupScript(script, worktree: worktree.path, projectRoot: project.rootPath, environment: portEnvironment(in: worktree.path, projectID: project.id))
            }
            try Task.checkCancellation()
        } catch {
            // A fresh task, so the rollback still runs when the launch was cancelled.
            let (rollback, root) = (worktree, project.rootPath)
            await Task.detached { try? await git.discardWorktree(rollback, projectRoot: root) }.value
            throw error
        }
        return worktree
    }

    func setupScript(for project: Project, worktree: URL) -> URL? {
        if let explicit = project.setupScriptPath { return explicit }
        return [worktree, project.rootPath]
            .map { $0.appending(path: Project.defaultSetupScript) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Starts or resumes the provider, reporting a failure on the tile.
    func startProvider(_ id: UUID, message: UserMessage?, resumeID: String?, cut: ConversationCut? = nil) async {
        do {
            try await startProviderOrThrow(id, message: message, resumeID: resumeID, cut: cut)
        } catch is CancellationError where resumeID != nil {
            return
        } catch {
            if resumeID == nil {
                failLaunch(id, error)
            } else {
                apply(.failed(.processExited, message: "Couldn't resume: \(LaunchFailure.message(for: error))"), to: id)
            }
        }
    }

    func startProviderOrThrow(_ id: UUID, message: UserMessage?, resumeID: String?, cut: ConversationCut? = nil, instructions: String? = nil) async throws {
        guard let session = sessionsByID[id] else { return }
        if resumeID == nil { setStage(.starting, for: id) }
        // A Keychain read can wait on an access prompt, so it stays off the main actor.
        let (secrets, projectID) = (services.secrets, session.projectID)
        var environment = await Task.detached { (try? secrets.environment(sessionID: id, projectID: projectID)) ?? [:] }.value
        environment.merge(portEnvironment(in: session.worktreePath, projectID: projectID)) { secret, _ in secret }
        var launch = SessionLaunch(
            sessionID: id,
            workingDirectory: session.worktreePath,
            model: session.model,
            permissionMode: session.permissionMode,
            prompt: nil,
            environment: environment,
            mcpServer: services.bridge.serverConfig(for: id, helper: services.mcpHelper),
            resumeID: resumeID
        )
        launch.message = message
        launch.turnSettings = session.turnSettings
        launch.cut = cut
        launch.instructions = instructions
        // Nothing sent to an earlier process is still waiting for its checkpoint.
        pendingCheckpointCommits[id] = nil
        if message != nil { await takeCheckpoint(of: id) }
        let handle = try await services.adapter(for: session.provider).start(launch)
        if Task.isCancelled {
            await handle.stop()
            throw CancellationError()
        }
        attach(handle)
        trackPullRequest(for: id)
        // A resume without a prompt has nothing to do until you reply.
        if resumeID != nil, message == nil, sessionsByID[id]?.runState == .interrupted {
            update(id) { $0 = SessionReducer.ready($0) }
            flushQueue(id)
        }
    }

    private func setStage(_ stage: LaunchStage, for id: UUID) {
        update(id) { $0.runState = .preparing(stage) }
    }

    private func failLaunch(_ id: UUID, _ error: any Error) {
        guard let session = sessionsByID[id] else { return }
        let stage: LaunchStage = if case .preparing(let stage) = session.runState { stage } else { .starting }
        let message = error is CancellationError ? "Stopped during launch" : LaunchFailure.message(for: error)
        Log.session.error("Launch failed at \(stage.rawValue, privacy: .public): \(message, privacy: .public)")
        apply(.failed(.launch(stage), message: message), to: id)
    }

    func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard var session = sessionsByID[id] else { return }
        change(&session)
        sessionsByID[id] = session
        persist(id)
    }
}

enum LaunchFailure {
    static func message(for error: any Error) -> String {
        switch error {
        case let error as GitError:
            switch error {
            case .notARepository(let url): "\(url.lastPathComponent) isn't a git repository"
            case .noDefaultBranch: "Couldn't find the default branch"
            case .commandFailed(let arguments, _, let stderr):
                "git \(arguments.first ?? ""): \(LiveOutput.lastLine(of: stderr) ?? "failed")"
            case .invalidBranchName(let name): "Invalid branch name \(name)"
            case .setupScriptFailed(let status, let output):
                "Setup script exited \(status): \(LiveOutput.lastLine(of: output) ?? "")"
            case .refusedToRemove(let url): "Refused to remove \(url.path(percentEncoded: false))"
            case .refusedToDeleteBranch(let branch): "Refused to delete \(branch)"
            }
        case let error as ProviderError:
            switch error {
            case .binaryNotFound(let name): "\(name) isn't installed or isn't on your PATH"
            case .protocolViolation(let detail): "Unexpected reply from the provider: \(detail)"
            case .processExited(let code): "The provider exited with code \(code)"
            }
        default:
            error.localizedDescription
        }
    }
}
