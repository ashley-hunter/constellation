import ConstellationCore
import Foundation

/// Maps Claude Code stream-json frames to session events, and builds the frames sent back.
///
/// Pure state machine: the session actor feeds it decoded stdout lines and writes its replies.
struct ClaudeCodeTranslator {
    struct Output: Equatable {
        var events: [SessionEvent] = []
        /// Frames to write back to the CLI straight away.
        var replies: [JSONValue] = []
    }

    private struct PendingAsk {
        var ask: Ask
        var toolName: String
        var input: JSONValue
        var suggestions: [JSONValue]
    }

    private enum TurnEnd {
        case succeeded, failed, interrupted
    }

    /// The CLI's turn. It runs from your message or the CLI's running state to its result, and
    /// the CLI's idle closes it. An interrupt only counts against a running turn.
    private enum Turn: Equatable {
        case idle
        case running(interruptRequested: Bool)
        /// The result is in and idle is next.
        case ended(TurnEnd)

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
    }

    static let secretToolName = "mcp__\(MCPServerConfig.serverName)__request_secret"
    static let fileWritingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    let sessionID: UUID
    private(set) var nativeID: String
    /// Under Ask for risky, read-only Bash commands are allowed without raising an ask.
    var permissionMode = PermissionMode.default
    private let workingDirectory: String
    private let now: @Sendable () -> Date

    private var pendingAsks: [String: PendingAsk] = [:]
    private var secretToolUseIDs: Set<String> = []
    private var turn = Turn.idle
    /// The running turn's API error, which names the failure reason in its result.
    private var lastAPIError: String?
    /// The uuid of the conversation's latest message, which `--resume-session-at` can resume at.
    private(set) var head: String?
    /// The main conversation's last model call: everything it sent and got back is now context.
    private var contextTokens: Int?
    private var contextModel: String?
    /// `total_cost_usd` is cumulative for the process; only used when the per-result breakdown is missing.
    private var reportedCostUSD = 0.0

    init(sessionID: UUID, nativeID: String, workingDirectory: URL, now: @escaping @Sendable () -> Date = { .now }) {
        self.sessionID = sessionID
        self.nativeID = nativeID
        self.workingDirectory = Self.normalized(workingDirectory.standardizedFileURL.path(percentEncoded: false))
        self.now = now
    }

    var pendingAskIDs: Set<String> { Set(pendingAsks.keys) }

    // MARK: Incoming frames

    mutating func handle(_ frame: JSONValue) -> Output {
        switch frame["type"]?.string {
        case "system": Output(events: handleSystem(frame))
        case "stream_event": Output(events: handleStreamEvent(frame))
        case "assistant": Output(events: handleAssistant(frame))
        case "user": Output(events: handleUser(frame))
        case "result": Output(events: handleResult(frame))
        case "control_request": handleControlRequest(frame)
        case "control_cancel_request": Output(events: handleCancel(frame))
        default: Output()
        }
    }

    /// A message went in: it starts a turn unless one is running or still waiting for idle.
    mutating func noteMessageSent() {
        if turn == .idle { startTurn() }
    }

    /// Ignored between turns, so it can't turn the next turn's failure into an interrupt.
    mutating func noteInterruptRequested() {
        if turn.isRunning { turn = .running(interruptRequested: true) }
    }

    private mutating func startTurn() {
        turn = .running(interruptRequested: false)
        lastAPIError = nil
    }

    /// Pending asks can no longer be answered once the process is gone. A crash only fails a turn
    /// that was running: one that ended already reported how.
    mutating func processExited(code: Int32, stopRequested: Bool, stderrTail: [String]) -> [SessionEvent] {
        // An ask is only raised mid-turn, even when the CLI didn't report running.
        let wasRunning = turn.isRunning || !pendingAsks.isEmpty
        var events = pendingAsks.keys.sorted().map { SessionEvent.askWithdrawn(askID: $0) }
        pendingAsks.removeAll()
        if !stopRequested, code != 0, wasRunning {
            let detail = stderrTail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            events.append(.failed(.processExited, message: detail ?? "Claude Code exited with code \(code)"))
        }
        events.append(.exited(code: code))
        return events
    }

    private mutating func handleSystem(_ frame: JSONValue) -> [SessionEvent] {
        switch frame["subtype"]?.string {
        case "init":
            guard let id = frame["session_id"]?.string, id != nativeID else { return [] }
            nativeID = id
            return [.started(nativeID: id)]
        case "session_state_changed":
            switch frame["state"]?.string {
            case "running":
                if !turn.isRunning { startTurn() }
                return [.runState(.working)]
            case "requires_action":
                return [.runState(.blocked)]
            case "idle":
                defer {
                    turn = .idle
                    lastAPIError = nil
                }
                return turn == .ended(.failed) || turn == .ended(.interrupted) ? [] : [.runState(.done)]
            default:
                return []
            }
        default:
            return []
        }
    }

    private func handleStreamEvent(_ frame: JSONValue) -> [SessionEvent] {
        guard frame["parent_tool_use_id"] == .null,
              let event = frame["event"], event["type"]?.string == "content_block_delta",
              let delta = event["delta"], delta["type"]?.string == "text_delta",
              let text = delta["text"]?.string, !text.isEmpty
        else { return [] }
        return [.assistantText(text, isFinal: false)]
    }

    private mutating func handleAssistant(_ frame: JSONValue) -> [SessionEvent] {
        if let error = frame["error"]?.string {
            lastAPIError = error
            return []
        }
        let isMainConversation = frame["parent_tool_use_id"] == .null
        if isMainConversation, let uuid = frame["uuid"]?.string { head = uuid }
        if isMainConversation, let usage = frame["message"]?["usage"] {
            contextTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (usage[$1]?.int ?? 0) }
            contextModel = frame["message"]?["model"]?.string ?? contextModel
        }
        return (frame["message"]?["content"]?.array ?? []).compactMap { block in
            switch block["type"]?.string {
            case "text":
                guard isMainConversation, let text = block["text"]?.string, !text.isEmpty else { return nil }
                return .assistantText(text, isFinal: true)
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
                let input = block["input"] ?? [:]
                if name == Self.secretToolName { secretToolUseIDs.insert(id) }
                return .toolCall(ToolCall(id: id, name: name, summary: summary(tool: name, input: input), files: filesWritten(tool: name, input: input)))
            default:
                return nil
            }
        }
    }

    private mutating func handleUser(_ frame: JSONValue) -> [SessionEvent] {
        if frame["parent_tool_use_id"] == .null, let uuid = frame["uuid"]?.string { head = uuid }
        return (frame["message"]?["content"]?.array ?? []).compactMap { block in
            guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
            let isError = block["is_error"]?.bool ?? false
            let summary = secretToolUseIDs.contains(id) && !isError
                ? "Secret provided (redacted)"
                : Self.firstLine(of: Self.text(of: block["content"]))
            return .toolResult(ToolResult(toolCallID: id, summary: summary, isError: isError))
        }
    }

    private mutating func handleResult(_ frame: JSONValue) -> [SessionEvent] {
        var events: [SessionEvent] = []
        if let usage = usage(of: frame) {
            events.append(.usage(usage))
        }

        if let head { events.append(.conversationHead(head)) }
        let subtype = frame["subtype"]?.string ?? ""
        let isError = frame["is_error"]?.bool ?? (subtype != "success")
        let aborted = frame["terminal_reason"]?.string?.hasPrefix("aborted") ?? false
        if !isError {
            turn = .ended(.succeeded)
        } else if turn == .running(interruptRequested: true) || aborted {
            turn = .ended(.interrupted)
            events.append(.interrupted)
        } else {
            turn = .ended(.failed)
            let errors = frame["errors"]?.array?.compactMap(\.string).joined(separator: "\n")
            let message = frame["result"]?.string ?? errors.flatMap { $0.isEmpty ? nil : $0 } ?? subtype
            let reason = Self.failureReason(apiError: lastAPIError, status: frame["api_error_status"]?.int)
            events.append(.failed(reason, message: message))
        }
        return events
    }

    /// What this result cost. `model_usage_since_last_result` covers exactly the calls since the last
    /// result; `total_cost_usd` and `modelUsage` are cumulative, and a resumed process starts them
    /// from the earlier processes' spend.
    private mutating func usage(of frame: JSONValue) -> TokenUsage? {
        var usage: TokenUsage
        if let models = frame["model_usage_since_last_result"]?.object, !models.isEmpty {
            usage = TokenUsage(inputTokens: 0, outputTokens: 0, costUSD: 0)
            for model in models.values {
                usage.inputTokens += (model["inputTokens"]?.int ?? 0) + (model["cacheCreationInputTokens"]?.int ?? 0)
                usage.outputTokens += model["outputTokens"]?.int ?? 0
                usage.cachedInputTokens += model["cacheReadInputTokens"]?.int ?? 0
                usage.costUSD? += model["costUSD"]?.number ?? 0
            }
        } else if let raw = frame["usage"] {
            usage = TokenUsage(
                inputTokens: (raw["input_tokens"]?.int ?? 0) + (raw["cache_creation_input_tokens"]?.int ?? 0),
                outputTokens: raw["output_tokens"]?.int ?? 0,
                cachedInputTokens: raw["cache_read_input_tokens"]?.int ?? 0
            )
            if let total = frame["total_cost_usd"]?.number {
                usage.costUSD = max(0, total - reportedCostUSD)
                reportedCostUSD = total
            }
        } else {
            return nil
        }
        usage.contextTokens = contextTokens
        let windows = (frame["model_usage_since_last_result"] ?? frame["modelUsage"])?.object ?? [:]
        usage.contextWindow = contextModel.flatMap { windows[$0]?["contextWindow"]?.int }
            ?? windows.values.compactMap { $0["contextWindow"]?.int }.max()
        return usage
    }

    private mutating func handleControlRequest(_ frame: JSONValue) -> Output {
        guard let requestID = frame["request_id"]?.string, let request = frame["request"] else { return Output() }
        guard request["subtype"]?.string == "can_use_tool",
              let toolName = request["tool_name"]?.string
        else {
            let subtype = request["subtype"]?.string ?? "unknown"
            return Output(replies: [Self.controlError(requestID: requestID, message: "Unsupported control request: \(subtype)")])
        }

        let input = request["input"] ?? [:]
        if permissionMode == .askForRisky, toolName == "Bash",
           let command = input["command"]?.string, ReadOnlyCommand.isReadOnly(command) {
            return Output(replies: [Self.success(requestID: requestID, Self.allow(input))])
        }
        let kind: AskKind = switch toolName {
        case "AskUserQuestion":
            .question(QuestionAsk(questions: Self.questions(from: input)))
        default:
            .permission(PermissionAsk(
                toolName: toolName,
                summary: summary(tool: toolName, input: input),
                inputPreview: Self.preview(tool: toolName, input: input, description: request["description"]?.string),
                offeredDecisions: request["suppress_always_allow_rule"]?.bool == true
                    ? [.allowOnce, .deny, .allowForSession]
                    : PermissionDecision.allCases
            ))
        }
        let ask = Ask(id: requestID, sessionID: sessionID, kind: kind, createdAt: now())
        pendingAsks[requestID] = PendingAsk(
            ask: ask,
            toolName: toolName,
            input: input,
            suggestions: request["permission_suggestions"]?.array ?? []
        )
        return Output(events: [.askRaised(ask)])
    }

    private mutating func handleCancel(_ frame: JSONValue) -> [SessionEvent] {
        guard let id = frame["request_id"]?.string, pendingAsks.removeValue(forKey: id) != nil else { return [] }
        return [.askWithdrawn(askID: id)]
    }

    // MARK: Answers

    /// The `control_response` frame that answers a pending ask. The ask stays pending if this throws.
    mutating func reply(to askID: String, with answer: AskAnswer) throws -> JSONValue {
        guard let pending = pendingAsks[askID] else {
            throw ProviderError.protocolViolation("No pending Claude Code ask with id \(askID)")
        }
        let decision: JSONValue
        switch (answer, pending.ask.kind) {
        case (.reply, _):
            // The reply itself follows as a user message, so the turn carries on with it.
            decision = Self.deny(Self.declinedForReply, interrupt: false)
        case (.permission(.deny), .permission):
            decision = Self.deny("The user denied this tool use.")
        case (.permission(let scope), .permission):
            decision = Self.allow(pending.input, permissions: Self.updatedPermissions(for: scope, pending))
        case (.questions(let answers), .question):
            var input = pending.input.object ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            decision = Self.allow(.object(input))
        default:
            throw ProviderError.protocolViolation("Answer \(answer) does not fit a \(pending.toolName) ask")
        }
        pendingAsks[askID] = nil
        return Self.success(requestID: askID, decision)
    }

    private static func success(requestID: String, _ decision: JSONValue) -> JSONValue {
        [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": decision],
        ]
    }

    /// Session scope re-targets the suggested rules at the session; always-in-project writes them
    /// to `.claude/settings.local.json`, falling back to a rule for the whole tool.
    private static func updatedPermissions(for scope: PermissionDecision, _ pending: PendingAsk) -> [JSONValue]? {
        let rules = pending.suggestions.filter { $0["type"]?.string == "addRules" }
        func retargeted(_ destination: String) -> [JSONValue] {
            rules.compactMap { rule in
                guard var object = rule.object else { return nil }
                object["destination"] = .string(destination)
                return .object(object)
            }
        }
        switch scope {
        case .allowOnce, .deny:
            return nil
        case .allowForSession:
            let session = rules.isEmpty
                ? pending.suggestions.filter { $0["destination"]?.string == "session" }
                : retargeted("session")
            return session.isEmpty ? nil : session
        case .allowAlwaysInProject:
            if !rules.isEmpty { return retargeted("localSettings") }
            return [[
                "type": "addRules",
                "rules": [["toolName": .string(pending.toolName)]],
                "behavior": "allow",
                "destination": "localSettings",
            ]]
        }
    }

    // MARK: Outgoing frames

    static func userMessage(_ text: String, uuid: String? = nil) -> JSONValue {
        userFrame(content: .string(text), uuid: uuid)
    }

    /// Images go in as `image` blocks and small PDFs as `document` blocks, ahead of the text.
    /// Other files are listed in the text as paths.
    static func userMessage(_ message: UserMessage, uuid: String? = nil) throws -> JSONValue {
        let text = message.promptText(for: .claudeCode)
        let inline = message.inlineAttachments(for: .claudeCode)
        guard !inline.isEmpty else { return userMessage(text, uuid: uuid) }
        var blocks: [JSONValue] = try inline.map { attachment in
            let data = try Data(contentsOf: attachment.storedURL)
            return [
                "type": .string(attachment.kind == .image ? "image" : "document"),
                "source": [
                    "type": "base64",
                    "media_type": .string(attachment.mimeType),
                    "data": .string(data.base64EncodedString()),
                ],
            ]
        }
        if !text.allSatisfy(\.isWhitespace) {
            blocks.append(["type": "text", "text": .string(text)])
        }
        return userFrame(content: .array(blocks), uuid: uuid)
    }

    /// The CLI stores the message under `uuid` when one is given, so it can be resumed at later.
    private static func userFrame(content: JSONValue, uuid: String?) -> JSONValue {
        var frame: [String: JSONValue] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": nil,
            "session_id": "",
        ]
        if let uuid { frame["uuid"] = .string(uuid) }
        return .object(frame)
    }

    static func controlRequest(id: String, subtype: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var request = fields
        request["subtype"] = .string(subtype)
        return ["type": "control_request", "request_id": .string(id), "request": .object(request)]
    }

    static func controlError(requestID: String, message: String) -> JSONValue {
        [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)],
        ]
    }

    private static func allow(_ input: JSONValue, permissions: [JSONValue]? = nil) -> JSONValue {
        var decision: [String: JSONValue] = ["behavior": "allow", "updatedInput": input]
        if let permissions { decision["updatedPermissions"] = .array(permissions) }
        return .object(decision)
    }

    static let declinedForReply = "The user declined this and replied instead. Their reply follows as their next message; carry on with it."

    private static func deny(_ message: String, interrupt: Bool? = nil) -> JSONValue {
        var decision: [String: JSONValue] = ["behavior": "deny", "message": .string(message)]
        if let interrupt { decision["interrupt"] = .bool(interrupt) }
        return .object(decision)
    }

    // MARK: Summaries

    static func failureReason(apiError: String?, status: Int?) -> FailureReason {
        switch apiError {
        case "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required":
            return .auth
        case "rate_limit", "billing_error":
            return .usageLimit
        default:
            break
        }
        switch status {
        case 401, 403: return .auth
        case 429: return .usageLimit
        default: return .turnError
        }
    }

    private func summary(tool: String, input: JSONValue) -> String {
        let text: String? = switch tool {
        case "Bash": input["command"]?.string
        case "Edit", "Write", "MultiEdit", "Read": input["file_path"]?.string.map(relativePath)
        case "NotebookEdit": input["notebook_path"]?.string.map(relativePath)
        case "Grep", "Glob": input["pattern"]?.string
        case "WebFetch": input["url"]?.string
        case "WebSearch": input["query"]?.string
        default: input["description"]?.string
        }
        return Self.firstLine(of: text ?? tool)
    }

    private func filesWritten(tool: String, input: JSONValue) -> [String] {
        guard Self.fileWritingTools.contains(tool),
              let path = (input["file_path"] ?? input["notebook_path"])?.string
        else { return [] }
        return [relativePath(path)]
    }

    /// Worktree-relative, so sessions in different worktrees of a project can share file names.
    private func relativePath(_ path: String) -> String {
        let path = Self.normalized(path)
        let root = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func questions(from input: JSONValue) -> [QuestionAsk.Question] {
        (input["questions"]?.array ?? []).compactMap { question in
            guard let prompt = question["question"]?.string else { return nil }
            return QuestionAsk.Question(
                id: prompt,
                header: question["header"]?.string ?? "",
                prompt: prompt,
                options: (question["options"]?.array ?? []).compactMap { option in
                    option["label"]?.string.map { QuestionAsk.Option(label: $0, description: option["description"]?.string) }
                },
                multiSelect: question["multiSelect"]?.bool ?? false
            )
        }
    }

    private static func preview(tool: String, input: JSONValue, description: String?) -> String? {
        switch tool {
        case "Bash":
            return description ?? input["description"]?.string
        case "Write":
            return input["content"]?.string
        case "Edit":
            return diff(old: input["old_string"]?.string, new: input["new_string"]?.string)
        case "MultiEdit":
            return (input["edits"]?.array ?? [])
                .map { diff(old: $0["old_string"]?.string, new: $0["new_string"]?.string) }
                .joined(separator: "\n")
        default:
            return input == .object([:]) ? nil : input.prettyPrinted
        }
    }

    private static func diff(old: String?, new: String?) -> String {
        let removed = (old ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
        let added = (new ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return (removed + added).joined(separator: "\n")
    }

    private static func text(of content: JSONValue?) -> String {
        switch content {
        case .string(let text): text
        case .array(let blocks): blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: ""
        }
    }

    static func firstLine(of text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
