import ConstellationCore
import Foundation

/// New sessions start as drafts: a dashed tile and an open panel, made from the defaults. Nothing
/// touches disk or starts a process until the first message is sent. An empty draft is thrown away
/// on esc; one with text or attachments is stored, so it survives a restart.
extension AppModel {
    // MARK: Creating

    /// Where ⌘N starts a session: the targeted tile's project, then the one shown alone, then the
    /// last used one, then the first.
    func newSessionProjectID(for item: TileItem?) -> UUID? {
        let fromItem: UUID? = switch item {
        case .session(let id)?: sessionsByID[id]?.projectID
        case .terminal(let id)?: terminalsByID[id]?.projectID
        case nil: nil
        }
        return [fromItem, projectFilter, lastUsedProjectID].compactMap { $0 }.first { project($0) != nil } ?? projects.first?.id
    }

    var lastUsedProjectID: UUID? {
        sessionsByID.values.max { $0.lastActivityAt < $1.lastActivityAt }?.projectID
    }

    /// Opens a draft in the project, reusing an empty one already there. With no project yet, asks
    /// for a folder first.
    func newDraft(in projectID: UUID?, fromLauncher: Bool = false) {
        guard let project = project(projectID) ?? projects.first else {
            presentProjectFlow(.openFolder)
            return
        }
        let overLauncher = fromLauncher || showsLauncher
        let id = sessions.first { $0.isDraft && $0.projectID == project.id && chatDraft(for: $0.id).isEmpty }?.id
            ?? makeDraft(in: project)
        clearFront()
        launcher.launch = overLauncher ? EmptyLauncher.Launch(draftID: id) : nil
        openSession(id)
        composerFocusRequest = id
    }

    private func makeDraft(in project: Project) -> UUID {
        var session = Session(
            projectID: project.id,
            provider: settings.defaultProvider,
            model: settings.defaultModel,
            permissionMode: settings.defaultPermissionMode,
            title: "New session",
            worktreePath: project.rootPath,
            usesWorktree: settings.defaultNewWorktree,
            branch: "",
            baseBranch: project.defaultBranch,
            runState: .draft
        )
        session.effort = settings.defaultEffort
        sessionsByID[session.id] = session
        return session.id
    }

    // MARK: Settings pills

    func moveDraft(_ id: UUID, to projectID: UUID) {
        guard let project = project(projectID) else { return }
        updateDraftSession(id) {
            $0.projectID = project.id
            $0.worktreePath = project.rootPath
            $0.baseBranch = project.defaultBranch
        }
    }

    /// A new provider starts on its default model and effort.
    func setDraftProvider(_ id: UUID, _ provider: Provider) {
        let model = provider == settings.defaultProvider ? settings.defaultModel : ComposerDraft.models(for: provider)[0].id
        updateDraftSession(id) {
            $0.provider = provider
            $0.model = model
            $0.effort = provider == settings.defaultProvider ? settings.defaultEffort : nil
            $0.fastMode = false
        }
    }

    /// Picked by hand, from the chip or ⌥W, so it sticks for this draft.
    func setDraftWorktree(_ id: UUID, _ usesWorktree: Bool) {
        guard sessionsByID[id]?.isDraft == true else { return }
        draftsPlacedByHand.insert(id)
        updateDraftSession(id) { $0.usesWorktree = usesWorktree }
    }

    /// Until it's picked by hand, the chip follows the prompt: a question runs in the project
    /// folder, anything else where new sessions usually run.
    func placeDraftFromPrompt(_ id: UUID) {
        guard let session = sessionsByID[id], session.isDraft, !draftsPlacedByHand.contains(id) else { return }
        let usesWorktree = settings.defaultNewWorktree && !QuestionPrompt.isQuestion(chatDraft(for: id).text)
        if session.usesWorktree != usesWorktree { updateDraftSession(id) { $0.usesWorktree = usesWorktree } }
    }

    /// The draft runs in the project folder because its prompt reads as a question.
    func draftIsPlacedAsQuestion(_ id: UUID) -> Bool {
        guard let session = sessionsByID[id], session.isDraft, !session.usesWorktree, !draftsPlacedByHand.contains(id) else { return false }
        return QuestionPrompt.isQuestion(chatDraft(for: id).text)
    }

    func setDraftBaseBranch(_ id: UUID, _ branch: String) {
        updateDraftSession(id) { $0.baseBranch = branch }
    }

    private func updateDraftSession(_ id: UUID, _ change: (inout Session) -> Void) {
        guard sessionsByID[id]?.isDraft == true else { return }
        update(id, change)
    }

    /// Branches the "from" chip offers, the project's default first.
    func baseBranchChoices(for session: Session) async -> [String] {
        guard let project = project(session.projectID) else { return [] }
        let (git, root) = (services.git, project.rootPath)
        let local = await Task.detached { (try? await git.localBranches(of: root)) ?? [] }.value
        return [project.defaultBranch] + local.filter { $0 != project.defaultBranch }
    }

    // MARK: Sending and closing

    /// Sends the first message: the draft becomes a session and runs the staged launch.
    func startDraft(_ id: UUID) {
        guard var session = sessionsByID[id], session.isDraft, let project = project(session.projectID) else { return }
        let draft = chatDraft(for: id)
        guard !draft.isEmpty else { return }
        let message = UserMessage(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: draft.attachments)
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        chatDrafts[id] = nil
        rememberPrompt(message.text, for: session)
        if draftIsPlacedAsQuestion(id) { questionLaunches.insert(id) }
        draftsPlacedByHand.remove(id)

        session.title = SessionTitle.make(from: message.text.isEmpty ? (message.attachments.first?.name ?? "") : message.text)
        session.runState = .preparing(.fetch)
        session.worktreePath = project.rootPath
        session.branch = ""
        session.lastActivityAt = .now
        session.turnStartedAt = .now
        sessionsByID[id] = session
        lastPrompts[id] = message
        if launcher.launch?.draftID == id {
            launcher.launch = nil
            if launcher.presence == .summoned { launcher.presence = .auto }
        }
        focusedItem = .session(id)
        startedDraftID = id
        // Written now, not on the next dirty save, so a quit right after can't leave a messageless
        // draft row that the next launch would drop along with its running launch.
        do {
            try services.store.save(session)
            try services.store.clearDraftMessage(for: id)
        } catch {
            Log.app.error("Saving a started draft failed: \(error, privacy: .public)")
        }
        startLaunch(id, message: message)
    }

    /// esc, Cancel or a click outside an open draft. An empty one is discarded, shrinking back into
    /// the launcher row it came from; one with something written stays as a draft tile. Returns
    /// false for a session that isn't a draft.
    func closeDraft(_ id: UUID) -> Bool {
        guard sessionsByID[id]?.isDraft == true else { return false }
        if !chatDraft(for: id).isEmpty {
            launcher.launch = nil
            openedSessionID = nil
            focusedItem = .session(id)
        } else {
            // Kept, and still focused, until its panel has gone, so asking again turns it around.
            discardingDraftID = id
            openedSessionID = nil
        }
        return true
    }

    /// The opened session's panel has finished leaving: an empty draft closed with esc is thrown away.
    func finishClosingDraft(_ id: UUID) {
        guard discardingDraftID == id else { return }
        discardingDraftID = nil
        guard openedSessionID != id, chatDraft(for: id).isEmpty else { return }
        discardDraft(id)
    }

    /// Leaves an open draft for somewhere else, such as a jump or onboarding, with no morph: an
    /// empty one is discarded and one with something written stays as a draft tile.
    func leaveOpenDraft() {
        guard let id = openedSessionID, sessionsByID[id]?.isDraft == true else { return }
        if chatDraft(for: id).isEmpty {
            discardDraft(id)
        } else {
            launcher.launch = nil
            openedSessionID = nil
        }
    }

    func discardDraft(_ id: UUID) {
        guard sessionsByID[id]?.isDraft == true else { return }
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        sessionsByID[id] = nil
        chatDrafts[id] = nil
        draftsPlacedByHand.remove(id)
        if discardingDraftID == id { discardingDraftID = nil }
        if openedSessionID == id { openedSessionID = nil }
        if focusedItem == .session(id) { focusedItem = nil }
        if launcher.launch?.draftID == id { launcher.launch = nil }
        do { try services.store.deleteSession(id) } catch { Log.app.error("Discarding a draft failed: \(error, privacy: .public)") }
    }

    // MARK: Storing

    /// Drafts are written straight to the store, a moment after the last change, and only once
    /// there is something in them.
    func saveDraftSoon(_ id: UUID) {
        draftSaveTasks[id]?.cancel()
        draftSaveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow(id)
        }
    }

    func saveDraftNow(_ id: UUID) {
        draftSaveTasks.removeValue(forKey: id)?.cancel()
        guard let session = sessionsByID[id], session.isDraft else { return }
        let draft = chatDraft(for: id)
        do {
            if draft.isEmpty {
                try services.store.deleteSession(id)
            } else {
                try services.store.saveDraft(session, message: UserMessage(text: draft.text, attachments: draft.attachments))
            }
        } catch {
            Log.app.error("Saving a draft failed: \(error, privacy: .public)")
        }
    }

    func saveDraftsNow() {
        for session in sessionsByID.values where session.isDraft { saveDraftNow(session.id) }
    }

    /// Puts each stored draft's text back in its composer. A draft with nothing kept is dropped.
    func restoreDrafts() {
        let messages = (try? services.store.draftMessages()) ?? [:]
        for session in sessionsByID.values where session.isDraft {
            if let message = messages[session.id], !message.isEmpty {
                chatDrafts[session.id] = ChatDraft(text: message.text, attachments: message.attachments)
            } else {
                sessionsByID[session.id] = nil
                try? services.store.deleteSession(session.id)
            }
        }
    }
}
