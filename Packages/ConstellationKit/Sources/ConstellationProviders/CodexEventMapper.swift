import ConstellationCore
import Foundation

/// Turns one Codex thread's notifications and server requests into `SessionEvent`s,
/// and turns answers to its asks back into JSON-RPC responses.
struct CodexEventMapper {
    /// What answering an ask sends to Codex.
    struct Reply {
        var response: (id: CodexRequestID, result: CodexJSON)
        /// A message that steers the running turn, or starts a new one.
        var followUp: String?
    }

    enum AnswerError: Error, Equatable {
        case unknownAsk(String)
        case mismatchedAnswer(String)
    }

    private enum PendingAsk {
        case command(amendment: [String]?)
        case fileChange
        case permissions(requested: CodexJSON)
        case userInput(questionIDs: [String], secretQuestionID: String?)
    }

    let sessionID: UUID
    let workingDirectory: String

    private(set) var activeTurnID: String?
    private var lastCompletedTurnID: String?
    private var lastRunState: ProviderRunState?
    private var pending: [String: (requestID: CodexRequestID, ask: PendingAsk)] = [:]
    var hasPendingAsks: Bool { !pending.isEmpty }
    private var fileChanges: [String: [CodexItem.FileChange]] = [:]
    /// The current turn's last error that Codex won't retry, for a failure that comes without one.
    private var lastErrorMessage: String?

    init(sessionID: UUID, workingDirectory: String) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
    }

    /// Records the turn a `turn/start` response named, unless its notifications already finished it.
    mutating func turnStarted(_ turnID: String) {
        if turnID != lastCompletedTurnID { activeTurnID = turnID }
    }

    // MARK: Codex to Constellation

    mutating func map(_ message: CodexServerMessage) -> [SessionEvent] {
        do {
            if let id = message.requestID {
                return try mapRequest(message, id: id)
            }
            return try mapNotification(message)
        } catch {
            return []
        }
    }

    private mutating func mapNotification(_ message: CodexServerMessage) throws -> [SessionEvent] {
        let params = message.params
        switch message.method {
        case CodexMethod.threadStatusChanged:
            let status = try params.decode(CodexThreadStatusChanged.self).status
            switch status.type {
            case "active":
                let flags = status.activeFlags ?? []
                return runState(flags.isEmpty ? .working : .blocked)
            case "systemError":
                return [.failed(.turnError, message: lastErrorMessage ?? "Codex hit a system error")]
            default:
                return []
            }

        case CodexMethod.turnStarted:
            activeTurnID = try params.decode(CodexTurnNotification.self).turn.id
            // A system error ends a turn without completing it, so its error can still be here.
            lastErrorMessage = nil
            return runState(.working)

        case CodexMethod.turnCompleted:
            return turnCompleted(try params.decode(CodexTurnNotification.self).turn)

        case CodexMethod.itemStarted:
            return itemStarted(try params.decode(CodexItemNotification.self).item)

        case CodexMethod.itemCompleted:
            return itemCompleted(try params.decode(CodexItemNotification.self).item)

        case CodexMethod.agentMessageDelta:
            return [.assistantText(try params.decode(CodexAgentMessageDelta.self).delta, isFinal: false)]

        case CodexMethod.tokenUsageUpdated:
            let usage = try params.decode(CodexTokenUsageUpdated.self).tokenUsage
            guard let last = usage.last else { return [] }
            // Codex counts cached input inside inputTokens.
            return [.usage(TokenUsage(
                inputTokens: max(0, last.inputTokens - last.cachedInputTokens),
                outputTokens: last.outputTokens,
                cachedInputTokens: last.cachedInputTokens,
                contextTokens: last.totalTokens ?? last.inputTokens + last.outputTokens,
                contextWindow: usage.modelContextWindow
            ))]

        case CodexMethod.serverRequestResolved:
            let askID = try params.decode(CodexServerRequestResolved.self).requestId.description
            guard pending.removeValue(forKey: askID) != nil else { return [] }
            return [.askWithdrawn(askID: askID)]

        case CodexMethod.error:
            let error = try params.decode(CodexErrorNotification.self)
            if !error.willRetry { lastErrorMessage = error.error.message }
            return []

        default:
            return []
        }
    }

    private mutating func runState(_ state: ProviderRunState) -> [SessionEvent] {
        guard state != lastRunState else { return [] }
        lastRunState = state
        return [.runState(state)]
    }

    private mutating func turnCompleted(_ turn: CodexTurn) -> [SessionEvent] {
        activeTurnID = nil
        lastCompletedTurnID = turn.id
        lastRunState = nil
        var events: [SessionEvent] = pending.keys.sorted().map { .askWithdrawn(askID: $0) }
        pending = [:]
        switch turn.status {
        case "completed":
            events.append(.runState(.done))
        case "interrupted":
            events.append(.interrupted)
        default:
            let message = turn.error?.message ?? lastErrorMessage ?? "The turn failed"
            events.append(.failed(Self.failureReason(turn.error?.codexErrorInfo), message: message))
        }
        lastErrorMessage = nil
        return events
    }

    static func failureReason(_ info: CodexJSON?) -> FailureReason {
        switch info?.stringValue {
        case "unauthorized": .auth
        case "usageLimitExceeded", "rateLimitExceeded", "sessionBudgetExceeded": .usageLimit
        default: .turnError
        }
    }

    private mutating func itemStarted(_ item: CodexItem) -> [SessionEvent] {
        switch item {
        case .commandExecution(let id, let command, let actions, _, _, _):
            return [.toolCall(ToolCall(id: id, name: "shell", summary: Self.commandSummary(command, actions)))]
        case .fileChange(let id, let changes, _):
            fileChanges[id] = changes
            let files = changes.map { relativePath($0.path) }
            return [.toolCall(ToolCall(id: id, name: "apply_patch", summary: "Edit " + files.joined(separator: ", "), files: files))]
        case .mcpToolCall(let id, let server, let tool, _):
            return [.toolCall(ToolCall(id: id, name: "\(server).\(tool)", summary: tool))]
        case .webSearch(let id, let query):
            return [.toolCall(ToolCall(id: id, name: "web_search", summary: query))]
        default:
            return []
        }
    }

    private mutating func itemCompleted(_ item: CodexItem) -> [SessionEvent] {
        switch item {
        case .userMessage:
            // The session handle records what you sent; see `CodexSessionHandle.send`.
            return []
        case .agentMessage(_, let text):
            return [.assistantText(text, isFinal: true)]
        case .commandExecution(let id, _, _, let status, let exitCode, let output):
            let failed = status != "completed" || (exitCode ?? 0) != 0
            return [.toolResult(ToolResult(toolCallID: id, summary: Self.commandResultSummary(status, exitCode, output), isError: failed))]
        case .fileChange(let id, _, let status):
            fileChanges[id] = nil
            return [.toolResult(ToolResult(toolCallID: id, summary: status, isError: status != "completed"))]
        case .mcpToolCall(let id, _, _, let status):
            return [.toolResult(ToolResult(toolCallID: id, summary: status, isError: status == "failed"))]
        case .webSearch(let id, let query):
            return [.toolResult(ToolResult(toolCallID: id, summary: query))]
        case .other:
            return []
        }
    }

    private mutating func mapRequest(_ message: CodexServerMessage, id: CodexRequestID) throws -> [SessionEvent] {
        let askID = id.description
        let kind: AskKind
        var createdAt = Date.now
        switch message.method {
        case CodexMethod.commandApproval:
            let params = try message.params.decode(CodexCommandApprovalParams.self)
            createdAt = Self.date(params.startedAtMs) ?? createdAt
            pending[askID] = (id, .command(amendment: params.proposedExecpolicyAmendment))
            kind = .permission(PermissionAsk(
                toolName: "shell",
                summary: Self.commandSummary(params.command ?? "", params.commandActions ?? []),
                inputPreview: params.reason,
                offeredDecisions: Self.offeredDecisions(params.availableDecisions)
            ))

        case CodexMethod.fileChangeApproval:
            let params = try message.params.decode(CodexFileChangeApprovalParams.self)
            createdAt = Self.date(params.startedAtMs) ?? createdAt
            pending[askID] = (id, .fileChange)
            let changes = fileChanges[params.itemId] ?? []
            let files = changes.map { relativePath($0.path) }
            let preview = changes.map { "--- \(relativePath($0.path))\n\($0.diff)" }.joined(separator: "\n")
            kind = .permission(PermissionAsk(
                toolName: "apply_patch",
                summary: files.isEmpty ? (params.reason ?? "Edit files") : "Edit " + files.joined(separator: ", "),
                inputPreview: preview.isEmpty ? params.reason : preview,
                offeredDecisions: [.allowOnce, .deny, .allowForSession]
            ))

        case CodexMethod.permissionsApproval:
            let params = try message.params.decode(CodexPermissionsApprovalParams.self)
            createdAt = Self.date(params.startedAtMs) ?? createdAt
            pending[askID] = (id, .permissions(requested: params.permissions))
            let preview = (try? JSONEncoder.pretty.encode(params.permissions)).flatMap { String(data: $0, encoding: .utf8) }
            kind = .permission(PermissionAsk(
                toolName: "permissions",
                summary: params.reason ?? "Grant additional sandbox permissions",
                inputPreview: preview,
                offeredDecisions: [.allowOnce, .deny, .allowForSession]
            ))

        case CodexMethod.requestUserInput:
            let params = try message.params.decode(CodexUserInputParams.self)
            let secret = params.questions.first { $0.isSecret == true }
            pending[askID] = (id, .userInput(questionIDs: params.questions.map(\.id), secretQuestionID: secret?.id))
            if let secret {
                kind = .secret(SecretAsk(name: Self.environmentName(secret.id), reason: secret.question))
            } else {
                kind = .question(QuestionAsk(questions: params.questions.map { question in
                    QuestionAsk.Question(
                        id: question.id,
                        header: question.header,
                        prompt: question.question,
                        options: (question.options ?? []).map { .init(label: $0.label, description: $0.description) }
                    )
                }))
            }

        default:
            return []
        }
        return [.askRaised(Ask(id: askID, sessionID: sessionID, kind: kind, createdAt: createdAt))]
    }

    /// The answer to send straight back, without an ask, for a read-only command under Ask for risky.
    /// Codex already runs those in its sandbox; this covers the ones it still asks about.
    static func autoApproval(for message: CodexServerMessage, mode: PermissionMode) -> CodexJSON? {
        guard mode == .askForRisky, message.method == CodexMethod.commandApproval,
              let command = (try? message.params.decode(CodexCommandApprovalParams.self))?.command,
              ReadOnlyCommand.isReadOnly(command)
        else { return nil }
        return try? CodexJSON(encoding: CodexDecisionResponse(decision: .string("accept")))
    }

    // MARK: Constellation to Codex

    mutating func reply(to askID: String, with answer: AskAnswer) throws -> Reply {
        guard let (requestID, ask) = pending[askID] else { throw AnswerError.unknownAsk(askID) }
        let reply: Reply
        switch ask {
        case .command(let amendment):
            reply = try decisionReply(requestID, answer) { decision in
                switch decision {
                case .allowOnce: .string("accept")
                case .allowForSession: .string("acceptForSession")
                case .allowAlwaysInProject:
                    if let amendment, !amendment.isEmpty {
                        .object(["acceptWithExecpolicyAmendment": .object(["execpolicy_amendment": .array(amendment.map(CodexJSON.string))])])
                    } else {
                        .string("acceptForSession")
                    }
                case .deny: .string("decline")
                }
            }

        case .fileChange:
            reply = try decisionReply(requestID, answer) { decision in
                switch decision {
                case .allowOnce: .string("accept")
                case .allowForSession, .allowAlwaysInProject: .string("acceptForSession")
                case .deny: .string("decline")
                }
            }

        case .permissions(let requested):
            let granted: (CodexJSON, String)
            var followUp: String?
            switch answer {
            case .permission(.allowOnce): granted = (requested, "turn")
            case .permission(.allowForSession), .permission(.allowAlwaysInProject): granted = (requested, "session")
            case .permission(.deny): granted = (.object([:]), "turn")
            case .reply(let text):
                granted = (.object([:]), "turn")
                followUp = text
            default: throw AnswerError.mismatchedAnswer(askID)
            }
            let result = try CodexJSON(encoding: CodexPermissionsResponse(permissions: granted.0, scope: granted.1))
            reply = Reply(response: (requestID, result), followUp: followUp)

        case .userInput(let questionIDs, let secretQuestionID):
            var answers: [String: [String]] = Dictionary(uniqueKeysWithValues: questionIDs.map { ($0, []) })
            switch answer {
            case .questions(let selected):
                for (id, values) in selected where answers[id] != nil { answers[id] = values }
            case .secret(let value, _):
                guard let secretQuestionID else { throw AnswerError.mismatchedAnswer(askID) }
                answers[secretQuestionID] = [value]
            case .secretDeclined:
                break
            case .reply(let text):
                for id in questionIDs { answers[id] = [text] }
            default:
                throw AnswerError.mismatchedAnswer(askID)
            }
            let result = try CodexJSON(encoding: CodexUserInputResponse(answers: answers.mapValues { .init(answers: $0) }))
            reply = Reply(response: (requestID, result))
        }
        pending[askID] = nil
        return reply
    }

    private func decisionReply(
        _ requestID: CodexRequestID,
        _ answer: AskAnswer,
        decision: (PermissionDecision) -> CodexJSON
    ) throws -> Reply {
        let chosen: CodexJSON
        var followUp: String?
        switch answer {
        case .permission(let permission):
            chosen = decision(permission)
        case .reply(let text):
            chosen = decision(.deny)
            followUp = text
        default:
            throw AnswerError.mismatchedAnswer(requestID.description)
        }
        let result = try CodexJSON(encoding: CodexDecisionResponse(decision: chosen))
        return Reply(response: (requestID, result), followUp: followUp)
    }

    // MARK: Helpers

    static func offeredDecisions(_ available: [CodexJSON]?) -> [PermissionDecision] {
        guard let available else { return PermissionDecision.allCases }
        let names = available.compactMap { $0.stringValue ?? $0.objectKeys.first }
        var offered: [PermissionDecision] = []
        if names.contains("accept") { offered.append(.allowOnce) }
        if names.contains("decline") || names.contains("cancel") { offered.append(.deny) }
        if names.contains("acceptForSession") { offered.append(.allowForSession) }
        if names.contains("acceptWithExecpolicyAmendment") { offered.append(.allowAlwaysInProject) }
        return offered.isEmpty ? PermissionDecision.allCases : offered
    }

    /// The parsed command when Codex offers one, otherwise the raw command line.
    static func commandSummary(_ command: String, _ actions: [CodexItem.CommandAction]) -> String {
        actions.isEmpty ? command : actions.map(\.command).joined(separator: " && ")
    }

    static func commandResultSummary(_ status: String, _ exitCode: Int?, _ output: String?) -> String {
        let lastLine = output?
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let lastLine { return String(lastLine) }
        if let exitCode { return "exit \(exitCode)" }
        return status
    }

    static func environmentName(_ id: String) -> String {
        String(id.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Paths relative to the session's directory, so related sessions in other worktrees compare equal.
    func relativePath(_ path: String) -> String {
        for root in [workingDirectory, "/private" + workingDirectory] {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }
}

private extension CodexJSON {
    var objectKeys: [String] {
        if case .object(let object) = self { Array(object.keys) } else { [] }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
