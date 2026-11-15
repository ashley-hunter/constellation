import ConstellationCore
import ConstellationMCP
import Foundation

/// What a session's provider process is doing.
enum ProcessPhase: Equatable {
    /// No process: a draft, or a session that ended, stopped or never started one.
    case none
    /// A launch, resume, rewind or fork is under way and hasn't attached a process yet.
    case launching
    /// A live process takes messages, answers and interrupts.
    case live
}

/// A launch in flight, with a token so a launch that was cancelled or replaced never clears its
/// successor's entry.
struct LaunchTask {
    let token: UUID
    let task: Task<Void, Never>
}

/// Running sessions: provider events in, your answers and replies out.
extension AppModel {
    // MARK: Process

    /// A launch attaches its handle as its last step, so launching and live never overlap.
    func processPhase(_ id: UUID) -> ProcessPhase {
        if handles[id] != nil { return .live }
        if launchTasks[id] != nil { return .launching }
        return .none
    }

    /// Runs `work` as the session's launch: the session reads launching until it finishes.
    func runLaunchTask(_ id: UUID, _ work: @escaping @MainActor (AppModel) async -> Void) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await work(self)
            if self.launchTasks[id]?.token == token { self.launchTasks[id] = nil }
        }
        launchTasks[id] = LaunchTask(token: token, task: task)
    }

    /// Lets go of the session's process: cancels a launch in flight, detaches the handle so its
    /// later events and its end are ignored, and ends a running turn with `ending`. Returns the
    /// handle, still running, for the caller to stop.
    @discardableResult
    func releaseProcess(_ id: UUID, endingTurnWith ending: SessionEvent) -> (any ProviderSessionHandle)? {
        launchTasks.removeValue(forKey: id)?.task.cancel()
        handleTokens[id] = nil
        let handle = handles.removeValue(forKey: id)
        if sessionsByID[id]?.runState.isTurnRunning == true { apply(ending, to: id) }
        return handle
    }

    // MARK: Events

    /// Each attach gets a token, so events and the end of a handle that was stopped or replaced
    /// never reach the session or forget its newer handle.
    func attach(_ handle: any ProviderSessionHandle) {
        let id = handle.sessionID
        let token = UUID()
        handles[id] = handle
        handleTokens[id] = token
        Task { [weak self] in
            for await event in handle.events {
                guard let self, self.handleTokens[id] == token else { continue }
                self.apply(event, to: id)
            }
            guard let self, self.handleTokens[id] == token else { return }
            self.handleEnded(id)
        }
    }

    private static func localServer(in event: SessionEvent) -> URL? {
        switch event {
        case .toolResult(let result): LocalServer.url(in: result.summary)
        case .assistantText(let text, isFinal: true): LocalServer.url(in: text)
        default: nil
        }
    }

    func apply(_ event: SessionEvent, to id: UUID, at time: Date = .now) {
        guard let before = sessionsByID[id] else { return }
        let event = withCheckpointCommit(Self.redacted(event), for: id)
        let after = SessionReducer.reduce(before, event, at: time)
        sessionsByID[id] = after
        appendOutput(event, for: id)
        if case .userMessage(let text, let attachments) = event {
            lastPrompts[id] = UserMessage(text: text, attachments: attachments ?? [])
        }
        if Self.isRecorded(event) { eventLog.yield((id, event, time)) }
        if case .usage(let report) = event { recordUsage(report, for: id, at: time) }
        if let url = Self.localServer(in: event) { localServers[after.projectID] = url }
        persist(id)
        if !before.runState.hasEndedTurn, after.runState.hasEndedTurn {
            refreshPullRequest(for: after)
        }
        if MessageQueue.shouldFlush(from: before.runState, to: after.runState) {
            flushQueue(id)
        }
    }

    private func handleEnded(_ id: UUID) {
        releaseProcess(id, endingTurnWith: .failed(.processExited, message: "The provider stopped unexpectedly"))
    }

    /// Streaming deltas are left out of the store: the final message carries the same text.
    private static func isRecorded(_ event: SessionEvent) -> Bool {
        if case .assistantText(_, isFinal: false) = event { return false }
        return true
    }

    private static func redacted(_ event: SessionEvent) -> SessionEvent {
        guard case .toolResult(var result) = event else { return event }
        result.summary = LiveOutput.redacted(result.summary)
        return .toolResult(result)
    }

    // MARK: Intents

    /// Answers an ask. A `request_secret` ask goes back over the MCP bridge; everything else to the provider.
    func answer(ask: Ask, with answer: AskAnswer) {
        guard let session = sessionsByID[ask.sessionID], session.pendingAsks.contains(where: { $0.id == ask.id }) else { return }
        if let requestID = mcpSecretRequests.removeValue(forKey: ask.id) {
            respondToSecret(requestID, ask: ask, session: session, answer: answer)
        } else if let handle = handles[ask.sessionID] {
            Task { [weak self] in
                do {
                    try await handle.answer(ask: ask, with: answer)
                } catch {
                    self?.notice = "Couldn't send your answer: \(error.localizedDescription)"
                }
            }
        } else {
            notice = "That session isn't running. Resume it to answer."
            return
        }
        sessionsByID[ask.sessionID] = SessionReducer.answered(session, askID: ask.id)
        persist(ask.sessionID)
    }

    private func respondToSecret(_ requestID: UUID, ask: Ask, session: Session, answer: AskAnswer) {
        var value: String?
        var scopes: [SecretStore.Scope] = []
        if case .secret(let secret, let saveForProject) = answer, case .secret = ask.kind {
            value = secret
            scopes = [.session(session.id)] + (saveForProject ? [.project(session.projectID)] : [])
        }
        let (secrets, bridge, name) = (services.secrets, services.bridge, ask.kind.secretName)
        Task { [weak self, value, scopes] in
            // A Keychain write can wait on an access prompt, so it stays off the main actor.
            if let value, let name {
                let failure = await Task.detached { () -> String? in
                    do {
                        for scope in scopes { try secrets.save(value, name: name, scope: scope) }
                        return nil
                    } catch {
                        return "Couldn't save \(name) to the Keychain: \(error)"
                    }
                }.value
                if let failure { self?.notice = failure }
            }
            await bridge.respond(toSecretRequest: requestID, value: value)
        }
        if case .reply(let text) = answer, let handle = handles[session.id] {
            Task { try? await handle.send(userMessage: text) }
        }
    }

    /// A reply while an ask is pending answers it in words; otherwise it goes to the provider now,
    /// resuming it first if its process is gone.
    func sendReply(_ message: UserMessage, to id: UUID) {
        guard !message.isEmpty, let session = sessionsByID[id] else { return }
        if let ask = session.nextAsk {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Typed in the reply box, it's your own answer to one question.
                if case .question(let question) = ask.kind, question.questions.count == 1 {
                    answer(ask: ask, with: .questions([question.questions[0].id: [text]]))
                } else {
                    answer(ask: ask, with: .reply(text))
                }
            }
            if !message.attachments.isEmpty { deliver(UserMessage(text: "", attachments: message.attachments), to: id) }
        } else {
            deliver(message, to: id)
        }
    }

    /// A turn is running in a live process, so it can stop without ending the session.
    func canInterrupt(_ id: UUID) -> Bool {
        processPhase(id) == .live && sessionsByID[id]?.runState == .working
    }

    /// An interrupted session whose process is gone. One interrupted in place takes a reply instead.
    func canResume(_ id: UUID) -> Bool {
        sessionsByID[id]?.runState == .interrupted && processPhase(id) == .none
    }

    /// ⌘. Stops the turn; the process stays, so the next message carries on.
    func interrupt(_ id: UUID) {
        guard let handle = handles[id] else { return }
        Task { try? await handle.interrupt() }
    }

    /// ⌘⌫. Ends the process; the session stays on the desktop as interrupted.
    func stop(_ id: UUID) {
        guard let handle = releaseProcess(id, endingTurnWith: .interrupted) else { return }
        Task { await handle.stop() }
    }

    /// Restarts the provider with its native id, for a session whose process is gone.
    func resume(_ id: UUID, message: UserMessage? = nil) {
        guard let session = sessionsByID[id], processPhase(id) == .none else { return }
        guard let nativeID = session.nativeID else {
            retryLaunch(id)
            return
        }
        runLaunchTask(id) { await $0.startProvider(id, message: message, resumeID: nativeID) }
    }

    /// Sessions that were live when Constellation went away pick up again, a few seconds apart so
    /// their providers don't all start at once. One cut off mid-turn is asked to carry on; one
    /// waiting on you is asked to try that step again, as its ask went with the old process.
    func resumeAfterRestart(_ resumes: [RestartResume]) {
        guard !resumes.isEmpty else { return }
        Task { [weak self] in
            for (index, pickup) in resumes.enumerated() {
                try? await Task.sleep(for: .seconds(index == 0 ? 1 : 2))
                guard let self, self.canResume(pickup.sessionID),
                      self.sessionsByID[pickup.sessionID]?.lifecycle != .archived else { continue }
                self.apply(.note(pickup.note), to: pickup.sessionID)
                switch pickup.kind {
                case .midTurn: self.resume(pickup.sessionID, message: UserMessage(text: RestartResume.continuation))
                case .waiting: self.resume(pickup.sessionID, message: UserMessage(text: RestartResume.askAgain))
                }
            }
        }
    }

    /// r. A launch that failed runs again from the start; a failed turn resends the last prompt;
    /// an interrupted session resumes.
    func retry(_ id: UUID) {
        if sessionsByID[id]?.runState == .interrupted { return resume(id) }
        guard let session = sessionsByID[id], case .failed(let reason) = session.runState else { return }
        if case .launch = reason {
            retryLaunch(id)
        } else if let prompt = lastPrompts[id] {
            sendReply(prompt, to: id)
        }
    }

    // MARK: MCP

    func handle(_ request: MCPBridgeRequest) {
        switch request {
        case let .requestSecret(requestID, sessionID, name, reason):
            guard sessionsByID[sessionID] != nil else {
                Task { await services.bridge.respond(toSecretRequest: requestID, value: nil) }
                return
            }
            let ask = Ask(id: "mcp-\(requestID.uuidString)", sessionID: sessionID, kind: .secret(SecretAsk(name: name, reason: reason)))
            mcpSecretRequests[ask.id] = requestID
            apply(.askRaised(ask), to: sessionID)
        case let .secretRequestWithdrawn(requestID):
            guard let askID = mcpSecretRequests.first(where: { $0.value == requestID })?.key else { return }
            mcpSecretRequests[askID] = nil
            guard let session = sessionsByID.values.first(where: { $0.asks.contains { $0.id == askID } }) else { return }
            apply(.askWithdrawn(askID: askID), to: session.id)
        case let .reportOutcome(sessionID, outcome):
            apply(.outcome(outcome), to: sessionID)
        }
    }
}

private extension AskKind {
    var secretName: String? {
        if case .secret(let request) = self { request.name } else { nil }
    }
}
