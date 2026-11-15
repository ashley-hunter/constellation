import ConstellationCore
import ConstellationGit
import Foundation

/// Rewind to here, waiting for you to confirm. `loss` fills in once git has worked it out.
struct RewindRequest: Identifiable, Hashable {
    let sessionID: UUID
    let messageIndex: Int
    let message: UserMessage
    let cut: ConversationCut
    let messagesLost: Int
    /// The worktree snapshot taken when the message was sent. Nil when files can't be reverted.
    let commit: String?
    var loss: CheckpointLoss?
    var lossError: String?
    var revertsFiles: Bool

    var id: String { "\(sessionID)-\(messageIndex)" }
}

/// Fork from here, Rewind to here, turn checkpoints and the live turn settings.
extension AppModel {
    // MARK: Checkpoints

    /// Snapshots the worktree before a message goes out. The commit joins the message's checkpoint
    /// when the provider reports it; snapshots wait in the order their messages were sent.
    func takeCheckpoint(of id: UUID) async {
        guard let session = sessionsByID[id] else { return }
        let commit = try? await services.git.snapshot(session.worktreePath, session: id)
        pendingCheckpointCommits[id, default: []].append(commit)
    }

    /// For a message that never reached the provider.
    func dropLastCheckpoint(of id: UUID) {
        _ = pendingCheckpointCommits[id]?.popLast()
    }

    func withCheckpointCommit(_ event: SessionEvent, for id: UUID) -> SessionEvent {
        guard case .checkpoint(var checkpoint) = event, checkpoint.commit == nil,
              let pending = pendingCheckpointCommits[id], !pending.isEmpty else { return event }
        checkpoint.commit = pendingCheckpointCommits[id]?.removeFirst() ?? nil
        if pendingCheckpointCommits[id]?.isEmpty == true { pendingCheckpointCommits[id] = nil }
        return .checkpoint(checkpoint)
    }

    /// Rewind and Fork need the provider's id, and no launch or resume in flight.
    func canBranch(_ session: Session) -> Bool {
        guard session.nativeID != nil, processPhase(session.id) != .launching else { return false }
        if case .preparing = session.runState { return false }
        return true
    }

    // MARK: Rewind

    func requestRewind(_ session: Session, transcript: Transcript, entryID: Int) {
        guard canBranch(session),
              let index = transcript.messageIndex(ofEntry: entryID),
              let cut = transcript.rewindCut(toMessage: index, provider: session.provider),
              case .user(_, let text, let attachments) = transcript.entries[entryID] else { return }
        let commit = transcript.checkpoint(forMessage: index)?.commit
        let request = RewindRequest(
            sessionID: session.id,
            messageIndex: index,
            message: UserMessage(text: text, attachments: attachments),
            cut: cut,
            messagesLost: transcript.messagesLost(rewindingTo: index),
            commit: commit,
            revertsFiles: commit != nil
        )
        rewindRequest = request
        guard let commit else { return }
        let (git, path) = (services.git, session.worktreePath)
        Task { [weak self] in
            let result = await Task.detached { () -> Result<CheckpointLoss, any Error> in
                do { return .success(try await git.loss(restoring: commit, in: path)) } catch { return .failure(error) }
            }.value
            guard let self, self.rewindRequest?.id == request.id else { return }
            switch result {
            case .success(let loss): self.rewindRequest?.loss = loss
            case .failure(let error):
                self.rewindRequest?.lossError = LaunchFailure.message(for: error)
                self.rewindRequest?.revertsFiles = false
            }
        }
    }

    /// Stops the provider, reverts the files if asked, cuts the transcript and resumes the provider
    /// at the cut. The message goes back into the composer so you can change it and send it again.
    func confirmRewind() {
        guard let request = rewindRequest, let session = sessionsByID[request.sessionID], let nativeID = session.nativeID else { return }
        rewindRequest = nil
        let id = session.id
        let running = releaseProcess(id, endingTurnWith: .interrupted)
        runLaunchTask(id) { model in
            // The old handle has to be gone before the provider resumes: Codex routes by thread id.
            await running?.stop()
            if request.revertsFiles, let commit = request.commit {
                do {
                    try await model.services.git.restore(commit, in: session.worktreePath)
                } catch {
                    model.notice = "Couldn't put the files back, so nothing was rewound: \(LaunchFailure.message(for: error))"
                    return
                }
            }
            model.apply(.rewound(toMessage: request.messageIndex), to: id)
            model.update(id) { $0 = SessionReducer.ready($0) }
            if model.chatDraft(for: id).isEmpty {
                model.updateDraft(id) {
                    $0.text = request.message.text
                    $0.attachments = request.message.attachments
                }
            }
            await model.startProvider(id, message: nil, resumeID: nativeID, cut: request.cut)
        }
    }

    // MARK: Fork

    /// A new session in a new worktree, branched from the source worktree's HEAD with its
    /// uncommitted changes carried over, whose conversation is the source's through this message's turn.
    func fork(_ source: Session, transcript: Transcript, entryID: Int) {
        guard canBranch(source), let sourceID = source.nativeID, let project = project(source.projectID),
              let index = transcript.messageIndex(ofEntry: entryID),
              let cut = transcript.forkCut(atMessage: index, provider: source.provider) else { return }
        var fork = Session(
            projectID: project.id,
            provider: source.provider,
            model: source.model,
            permissionMode: source.permissionMode,
            title: "\(source.title) (fork)",
            worktreePath: project.rootPath,
            branch: "",
            baseBranch: source.baseBranch,
            runState: .preparing(.worktree)
        )
        fork.turnSettings = source.turnSettings
        fork.turnStartedAt = .now
        sessionsByID[fork.id] = fork
        persist(fork.id)
        focusedItem = .session(fork.id)
        let id = fork.id
        runLaunchTask(id) { await $0.runFork(id, from: source, sourceNativeID: sourceID, project: project, messageIndex: index, cut: cut) }
    }

    private func runFork(_ id: UUID, from source: Session, sourceNativeID: String, project: Project, messageIndex: Int, cut: ConversationCut) async {
        let git = services.git
        var worktree: Worktree?
        do {
            let carried = try? await git.snapshot(source.worktreePath, session: id)
            let base = try await git.headCommit(of: source.worktreePath) ?? source.baseBranch
            var created = try await git.createWorktree(projectRoot: project.rootPath, projectName: project.name, base: base)
            worktree = created
            if let renamed = try? await git.rename(created, projectRoot: project.rootPath, to: BranchSlug.make(from: "\(source.title) fork"), moveDirectory: true) {
                created = renamed
                worktree = renamed
            }
            if let carried { try await git.restore(carried, in: created.path) }
            update(id) {
                $0.worktreePath = created.path
                $0.branch = created.branch
            }
            if let script = setupScript(for: project, worktree: created.path) {
                update(id) { $0.runState = .preparing(.setup) }
                try await git.runSetupScript(script, worktree: created.path, projectRoot: project.rootPath, environment: portEnvironment(in: created.path, projectID: project.id))
            }
            try Task.checkCancellation()
            await copyHistory(from: source.id, to: id, throughMessage: messageIndex, cut: cut)
            update(id) { $0.runState = .preparing(.starting) }
            try await startProviderOrThrow(id, message: nil, resumeID: sourceNativeID, cut: cut)
            update(id) {
                $0.runState = .done
                $0.turnEndedAt = .now
            }
        } catch {
            if let worktree {
                let root = project.rootPath
                await Task.detached { try? await git.discardWorktree(worktree, projectRoot: root) }.value
                update(id) {
                    $0.worktreePath = root
                    $0.branch = ""
                }
            }
            let stage: LaunchStage = if case .preparing(let stage) = sessionsByID[id]?.runState { stage } else { .starting }
            let message = error is CancellationError ? "Stopped during the fork" : LaunchFailure.message(for: error)
            apply(.failed(.launch(stage), message: "Couldn't fork: \(message)"), to: id)
        }
    }

    /// The source's transcript through the fork point goes into the fork's log, so it reads the
    /// same and its earlier messages can be rewound to: Claude Code keeps message ids in a fork,
    /// and Codex keeps turn ids.
    private func copyHistory(from sourceID: UUID, to id: UUID, throughMessage index: Int, cut: ConversationCut) async {
        let (store, recorder) = (services.store, services.recorder)
        try? await recorder.flush()
        let events = await Task.detached { (try? store.events(for: sourceID).map(\.event)) ?? [] }.value
        var history = Transcript.history(events, throughMessage: index)
        if case .fork(let through?) = cut, sessionsByID[id]?.provider == .claudeCode {
            history.append(.conversationHead(through))
        }
        let now = Date.now
        for event in history { eventLog.yield((id, event, now)) }
        var output = LiveOutput()
        for event in history { output.append(event) }
        setOutput(output, for: id)
    }

    // MARK: Turn settings

    /// The models a provider offers the pickers. Codex's come from `model/list`.
    func modelChoices(for provider: Provider) -> [ModelChoice] {
        modelCatalogs[provider] ?? []
    }

    /// Loads a provider's models the first time a picker shows.
    func loadModelChoices(for provider: Provider) async {
        guard modelCatalogs[provider] == nil, let catalog = services.adapter(for: provider) as? any ModelCatalog else { return }
        modelCatalogs[provider] = []
        do {
            modelCatalogs[provider] = try await catalog.models()
        } catch {
            Log.app.error("Listing \(provider.displayName, privacy: .public) models failed: \(error, privacy: .public)")
            modelCatalogs[provider] = nil
        }
    }

    /// Changes what the session's next turn runs with. A running provider picks it up when the
    /// next message goes out; a stopped one starts with it.
    func setTurnSettings(_ id: UUID, _ change: (inout TurnSettings) -> Void) {
        guard var settings = sessionsByID[id]?.turnSettings else { return }
        change(&settings)
        update(id) { $0.turnSettings = settings }
        if let handle = handles[id] as? any TurnSettingsAdjustable {
            Task { await handle.adjust(settings) }
        }
    }
}
