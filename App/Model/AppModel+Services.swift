import ConstellationCore
import ConstellationGitHub
import ConstellationProcess
import ConstellationStore
import Foundation

/// Start-up, background loops and shutdown.
extension AppModel {
    /// Loads the store (applying the restart rule), then starts the MCP socket, PR polling and the idle clock.
    func start() {
        startChildWatch()
        startEventLog()
        restore()
        restoreDrafts()
        restoreUsage()
        startBridge()
        startPullRequests()
        startIdleClock()
    }

    /// Stops children that crashed or killed runs left behind, then tracks new ones in this run's
    /// own folder and starts the watchdog that stops them if this run ends the same way. Another
    /// copy of the app running at the same time keeps its children.
    private func startChildWatch() {
        let base = services.childrenDirectory
        let leftovers = ChildRegistry.collectLeftovers(ofEndedRunsIn: base)
        if !leftovers.isEmpty {
            Log.app.notice("Stopping \(leftovers.count) children left by the last run: \(leftovers.map(\.name).joined(separator: ", "), privacy: .public)")
            Task.detached { await ChildRegistry.stop(leftovers) }
        }
        let directory = ChildRegistry.runDirectory(in: base)
        ChildRegistry.track(in: directory)
        do {
            watchdog = try ChildRegistry.startWatchdog(
                helper: services.mcpHelper,
                arguments: ["--watchdog", directory.path(percentEncoded: false)]
            )
        } catch {
            Log.app.error("Child watchdog didn't start: \(error, privacy: .public)")
        }
    }

    private func restore() {
        let restored: RestoredState
        do {
            restored = try services.store.restoreAtLaunch()
        } catch {
            notice = "Couldn't load saved sessions: \(error.localizedDescription)"
            return
        }
        // Give any projects that share a colour their own, once, and keep it.
        let projects = ProjectSwatch.unique(restored.projects)
        replaceProjects(projects)
        let recoloured = projects.filter { project in restored.projects.contains { $0.id == project.id && $0.swatch != project.swatch } }
        if !recoloured.isEmpty {
            let store = services.store
            Task.detached { for project in recoloured { try? store.save(project) } }
        }
        sessionsByID = Dictionary(uniqueKeysWithValues: restored.sessions.map { ($0.id, $0) })
        terminalsByID = Dictionary(uniqueKeysWithValues: restored.terminals.map { ($0.id, $0) })
        adoptSurvivingShells()
        #if DEBUG
        // `-ConstellationPretendWaiting <id,id>` shows those sessions waiting on their last ask, for
        // working on how a waiting card looks without a live agent.
        for id in (UserDefaults.standard.string(forKey: "ConstellationPretendWaiting") ?? "").split(separator: ",").compactMap({ UUID(uuidString: String($0)) }) {
            guard var session = sessionsByID[id], let last = session.asks.indices.last else { continue }
            session.runState = .blocked
            session.asks[last].status = .pending
            sessionsByID[id] = session
        }
        #endif
        settleSeenWorkAtLaunch()
        restorePileArrangement()
        restoreWorktreeNames()
        queues = Dictionary(grouping: restored.queuedMessages, by: \.sessionID)
        replayOutput(for: restored.sessions.map(\.id))
        resumeAfterRestart(restored.resumes)
    }

    /// Rebuilds each tile's last lines and last prompt from its stored events.
    private func replayOutput(for ids: [UUID]) {
        let store = services.store
        Task { [weak self] in
            for id in ids {
                let events = await Task.detached { (try? store.events(for: id)) ?? [] }.value
                var output = LiveOutput()
                var lastPrompt: UserMessage?
                for stored in events {
                    output.append(stored.event)
                    if case .userMessage(let text, let attachments) = stored.event {
                        lastPrompt = UserMessage(text: text, attachments: attachments ?? [])
                    }
                }
                self?.setOutput(output, for: id)
                if let lastPrompt { self?.lastPrompts[id] = lastPrompt }
            }
        }
    }

    private func startBridge() {
        let bridge = services.bridge
        Task { [weak self] in
            do {
                try await bridge.start()
            } catch {
                Log.app.error("MCP bridge failed to start: \(error, privacy: .public)")
                self?.notice = "Secrets and outcomes won't reach Constellation: the MCP socket didn't start."
            }
        }
        Task { [weak self] in
            for await request in bridge.requests {
                self?.handle(request)
            }
        }
    }

    // MARK: Pull requests

    private func startPullRequests() {
        let poller = services.pullRequests
        Task { [weak self] in
            await poller.start()
            for id in self?.sessionsByID.keys.map({ $0 }) ?? [] {
                self?.trackPullRequest(for: id)
            }
            for await update in poller.updates {
                self?.apply(update)
            }
        }
    }

    func trackPullRequest(for id: UUID) {
        guard let session = sessionsByID[id], session.usesWorktree, !session.branch.isEmpty,
              session.lifecycle != .archived, let project = project(session.projectID)
        else { return }
        let poller = services.pullRequests
        let (branch, isIdle) = (session.branch, session.lifecycle == .idle)
        Task { [weak self] in
            guard let repository = await self?.repository(for: project) else { return }
            await poller.track(repository: repository, branch: branch, sessionIsIdle: isIdle)
        }
    }

    func refreshPullRequest(for session: Session) {
        guard let repository = repositories[session.projectID] else { return }
        let poller = services.pullRequests
        Task { await poller.refresh(repository: repository) }
    }

    private func repository(for project: Project) async -> GitHubRepository? {
        if let known = repositories[project.id] { return known }
        let root = project.rootPath
        let resolved = await Task.detached { await GitHubRepository.resolve(repositoryAt: root) }.value
        repositories[project.id] = resolved
        return resolved
    }

    private func apply(_ update: PullRequestUpdate) {
        let projectIDs = Set(repositories.filter { $0.value == update.repository }.keys)
        for session in sessionsByID.values where projectIDs.contains(session.projectID) && session.branch == update.branch {
            self.update(session.id) { $0.pullRequest = update.pullRequest }
            // Only as it merges, so a session unsettled by hand isn't settled again by the next poll.
            if update.pullRequest?.state == .merged, session.pullRequest?.state != .merged {
                updateLifecycle(session.id, .pullRequestMerged)
            }
        }
    }

    // MARK: Idle

    /// Sessions with no activity for a day go idle. Checked every few minutes.
    private func startIdleClock() {
        Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func tick() {
        for id in sessionsByID.keys {
            updateLifecycle(id, .tick)
        }
    }

    // MARK: Quit

    var hasLiveSessions: Bool {
        sessionsByID.values.contains { $0.runState.isTurnRunning }
    }

    /// Marks live sessions interrupted so they can be resumed, stops every provider process, then saves.
    func shutDown() async {
        for id in launchTasks.keys { launchTasks.removeValue(forKey: id)?.task.cancel() }
        // Working and blocked sessions are saved as they are, so the next launch resumes them.
        let stopping = Array(handles.values)
        handles = [:]
        handleTokens = [:]
        await withTaskGroup(of: Void.self) { group in
            for handle in stopping {
                group.addTask { await handle.stop() }
            }
        }
        saveDirtySessions()
        saveDraftsNow()
        let store = services.store
        for session in sessionsByID.values where !session.isDraft { try? store.save(session) }
        eventLog.finish()
        await eventLogTask?.value
        try? await services.recorder.flush()
        await services.codex.shutdown()
        await services.bridge.stop()
        await services.pullRequests.stop()
    }
}
