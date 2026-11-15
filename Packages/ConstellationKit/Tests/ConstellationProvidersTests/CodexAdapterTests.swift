import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite(.timeLimit(.minutes(1)))
struct CodexAdapterReplayTests {
    let sessionID = UUID()

    func launch(_ mode: PermissionMode = .askForRisky, prompt: String?, resumeID: String? = nil) -> SessionLaunch {
        SessionLaunch(
            sessionID: sessionID,
            workingDirectory: URL(filePath: "/tmp/constellation-scratch/repo"),
            model: "",
            permissionMode: mode,
            prompt: prompt,
            mcpServer: MCPServerConfig(command: URL(filePath: "/usr/bin/true")),
            resumeID: resumeID
        )
    }

    func start(_ fixture: String, _ launch: SessionLaunch) async throws -> (CodexReplayTransport, any ProviderSessionHandle) {
        let transport = try CodexReplayTransport(fixture: fixture)
        let adapter = CodexAdapter(transport: { transport })
        return (transport, try await adapter.start(launch))
    }

    @Test func completedTurnEndsDone() async throws {
        let (transport, handle) = try await start("codex-completion", launch(prompt: "Reply with exactly the word: hello"))
        var events = handle.events.makeAsyncIterator()
        let seen = await collect(&events) { $0 == .runState(.done) }

        #expect(seen.first == .started(nativeID: "01a1a3ea-53db-7be1-a83c-7978ae1c2712"))
        #expect(seen.contains(.userMessage("Reply with exactly the word: hello")))
        #expect(seen.contains(.assistantText("hello", isFinal: false)))
        #expect(seen.contains(.assistantText("hello", isFinal: true)))
        #expect(seen.contains(.usage(TokenUsage(
            inputTokens: 7744, outputTokens: 5, cachedInputTokens: 13184, contextTokens: 20933, contextWindow: 475000
        ))))
        #expect(seen.filter(\.isRunState) == [.runState(.working), .runState(.done)])
        #expect(await transport.sentMethods() == ["initialize", "initialized", "thread/start", "turn/start"])
    }

    @Test func approvalsBecomeAsksAndDecisionsGoBack() async throws {
        let (transport, handle) = try await start(
            "codex-approvals",
            launch(.askForEverything, prompt: "Run the shell command `touch approved.txt` (do not use apply_patch), then reply done.")
        )
        var events = handle.events.makeAsyncIterator()

        let beforeCommandAsk = await collect(&events) { $0.raisedAsk != nil }
        #expect(beforeCommandAsk.contains(.runState(.blocked)))
        let commandAsk = try #require(beforeCommandAsk.last?.raisedAsk)
        guard case .permission(let permission) = commandAsk.kind else { Issue.record("expected a permission"); return }
        #expect(commandAsk.id == "0")
        #expect(permission.toolName == "shell")
        #expect(permission.summary == "touch approved.txt")
        #expect(permission.offeredDecisions == [.allowOnce, .deny, .allowAlwaysInProject])

        try await handle.answer(ask: commandAsk, with: .permission(.allowOnce))
        #expect(await transport.response(at: 0) == json(#"{"id":0,"result":{"decision":"accept"}}"#))

        let firstTurn = await collect(&events) { $0 == .runState(.done) }
        #expect(firstTurn.contains(.toolResult(ToolResult(toolCallID: "exec-3630d5be-016c-4936-86f1-5053b11a5ab9", summary: "exit 0"))))
        #expect(!firstTurn.contains { if case .askWithdrawn = $0 { true } else { false } })

        try await handle.send(userMessage: "Now create a file notes.txt containing the line hi, using apply_patch. Then reply done.")
        let beforeFileAsk = await collect(&events) { $0.raisedAsk != nil }
        #expect(beforeFileAsk.contains(.toolCall(ToolCall(
            id: "exec-491fd662-0acd-44ba-80ff-db1c9baa5f98", name: "apply_patch", summary: "Edit notes.txt", files: ["notes.txt"]
        ))))
        let fileAsk = try #require(beforeFileAsk.last?.raisedAsk)
        guard case .permission(let edit) = fileAsk.kind else { Issue.record("expected a permission"); return }
        #expect(edit.toolName == "apply_patch")
        #expect(edit.inputPreview == "--- notes.txt\nhi\n")

        try await handle.answer(ask: fileAsk, with: .permission(.deny))
        #expect(await transport.response(at: 1) == json(#"{"id":1,"result":{"decision":"decline"}}"#))

        let secondTurn = await collect(&events) { $0 == .runState(.done) }
        #expect(secondTurn.contains(.toolResult(ToolResult(toolCallID: "exec-491fd662-0acd-44ba-80ff-db1c9baa5f98", summary: "declined", isError: true))))
    }

    /// Codex's plan item isn't an ask: the turn after the answer just finishes.
    @Test func userInputBecomesAQuestion() async throws {
        let (transport, handle) = try await start("codex-question", launch(prompt: "Plan adding a greeting.txt file."))
        var events = handle.events.makeAsyncIterator()

        let questionAsk = try #require(await collect(&events) { $0.raisedAsk != nil }.last?.raisedAsk)
        guard case .question(let question) = questionAsk.kind else { Issue.record("expected a question"); return }
        #expect(question.questions.map(\.id) == ["greeting"])
        #expect(question.questions.first?.prompt == "Which greeting should greeting.txt contain?")
        #expect(question.questions.first?.options.map(\.label) == ["hello", "hi"])

        try await handle.answer(ask: questionAsk, with: .questions(["greeting": ["hello"]]))
        #expect(await transport.response(at: 0) == json(#"{"id":0,"result":{"answers":{"greeting":{"answers":["hello"]}}}}"#))

        let rest = await collect(&events) { $0 == .runState(.done) }
        #expect(rest.last == .runState(.done) && rest.allSatisfy { $0.raisedAsk == nil })
    }

    @Test func interruptEndsTheTurnInterrupted() async throws {
        let (transport, handle) = try await start("codex-interrupt", launch(.fullAuto, prompt: "Run the shell command `sleep 30` and then reply done."))
        var events = handle.events.makeAsyncIterator()

        _ = await collect(&events) { if case .toolCall(let call) = $0 { call.summary == "sleep 30" } else { false } }
        try await handle.interrupt()
        let interrupt = try #require(await transport.sent.last)
        #expect(interrupt["method"] == .string("turn/interrupt"))
        #expect(interrupt["params"]?["turnId"] == .string("01a1a3ea-8b45-7cf3-a888-d5abd39e8684"))

        #expect(await collect(&events) { $0 == .interrupted }.last == .interrupted)
    }

    @Test func resumeContinuesTheThread() async throws {
        let threadID = "01a1a3ea-53db-7be1-a83c-7978ae1c2712"
        let (transport, handle) = try await start("codex-resume", launch(prompt: "Reply with exactly the word: again", resumeID: threadID))
        var events = handle.events.makeAsyncIterator()

        let seen = await collect(&events) { $0 == .runState(.done) }
        #expect(seen.first == .started(nativeID: threadID))
        #expect(seen.contains(.assistantText("again", isFinal: true)))
        let resume = try #require(await transport.sent.first { $0["method"] == .string("thread/resume") })
        #expect(resume["params"]?["threadId"] == .string(threadID))
        #expect(resume["params"]?["config"]?["mcp_servers"]?["constellation"]?["command"] == .string("/usr/bin/true"))
    }

    @Test func instructionsGoInAsDeveloperInstructions() throws {
        var question = launch(prompt: "What does this do?")
        #expect(CodexAdapter.config(for: question).developerInstructions == nil)
        question.instructions = "Answer only."
        let encoded = try JSONValue.decode(JSONEncoder().encode(CodexAdapter.config(for: question)))
        #expect(encoded["developer_instructions"] == .string("Answer only."))
    }

    @Test func serverExitWithNoTurnOnlyExits() async throws {
        let (transport, handle) = try await start("codex-completion", launch(prompt: nil))
        var events = handle.events.makeAsyncIterator()
        _ = await transport.close()

        let seen = await collect(&events) { if case .exited = $0 { true } else { false } }
        #expect(seen.last == .exited(code: 0))
        #expect(!seen.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func serverExitMidTurnFailsTheSession() async throws {
        let (transport, handle) = try await start("codex-interrupt", launch(.fullAuto, prompt: "Run the shell command `sleep 30` and then reply done."))
        var events = handle.events.makeAsyncIterator()
        _ = await collect(&events) { if case .toolCall = $0 { true } else { false } }
        _ = await transport.close()

        let seen = await collect(&events) { if case .exited = $0 { true } else { false } }
        #expect(seen.suffix(2) == [.failed(.processExited, message: "codex app-server exited"), .exited(code: 0)])
    }

    @Test func stopInterruptsAndFinishesTheStream() async throws {
        let (transport, handle) = try await start("codex-interrupt", launch(.fullAuto, prompt: "Run the shell command `sleep 30` and then reply done."))
        var events = handle.events.makeAsyncIterator()
        _ = await collect(&events) { if case .toolCall = $0 { true } else { false } }

        await handle.stop()
        let rest = await collect(&events) { _ in false }
        #expect(rest.last == .interrupted)
        #expect(await transport.sentMethods().suffix(2) == ["turn/interrupt", "thread/unsubscribe"])
    }
}

@Suite struct CodexEventMapperTests {
    let sessionID = UUID()

    func mapper(raising request: String) throws -> (CodexEventMapper, Ask) {
        var mapper = CodexEventMapper(sessionID: sessionID, workingDirectory: "/repo")
        let frame = json(request)
        let message = CodexServerMessage(
            method: try #require(frame["method"]?.stringValue),
            params: frame["params"] ?? .null,
            requestID: try frame["id"].map { try $0.decode(CodexRequestID.self) }
        )
        let ask = try #require(mapper.map(message).first?.raisedAsk)
        return (mapper, ask)
    }

    func decision(_ request: String, _ answer: AskAnswer) throws -> CodexJSON? {
        var (mapper, ask) = try self.mapper(raising: request)
        return try mapper.reply(to: ask.id, with: answer).response.result["decision"]
    }

    let command = #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"i","command":"/bin/zsh -lc 'npm test'","commandActions":[{"type":"unknown","command":"npm test"}],"proposedExecpolicyAmendment":["npm","test"]}}"#
    let commandWithoutAmendment = #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"i","command":"ls"}}"#
    let fileChange = #"{"id":8,"method":"item/fileChange/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"i"}}"#
    let permissions = #"{"id":9,"method":"item/permissions/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"i","cwd":"/repo","reason":"needs network","permissions":{"network":{"enabled":true}}}}"#
    let secret = #"{"id":10,"method":"item/tool/requestUserInput","params":{"threadId":"t","turnId":"u","itemId":"i","isBlocking":true,"questions":[{"id":"stripe_key","header":"Key","question":"Paste the Stripe key","isSecret":true,"options":null}]}}"#

    @Test func commandDecisionsCoverEveryScope() throws {
        #expect(try decision(command, .permission(.allowOnce)) == .string("accept"))
        #expect(try decision(command, .permission(.allowForSession)) == .string("acceptForSession"))
        #expect(try decision(command, .permission(.allowAlwaysInProject)) == json(#"{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["npm","test"]}}"#))
        #expect(try decision(commandWithoutAmendment, .permission(.allowAlwaysInProject)) == .string("acceptForSession"))
        #expect(try decision(command, .permission(.deny)) == .string("decline"))
        // Without availableDecisions every scope is offered.
        let (_, ask) = try self.mapper(raising: command)
        guard case .permission(let permission) = ask.kind else { Issue.record("expected a permission"); return }
        #expect(permission.offeredDecisions == PermissionDecision.allCases)
        #expect(permission.summary == "npm test")
    }

    @Test func readOnlyCommandsAreAcceptedWithoutAskingUnderAskForRisky() throws {
        func message(_ request: String) throws -> CodexServerMessage {
            let frame = json(request)
            return CodexServerMessage(method: try #require(frame["method"]?.stringValue), params: frame["params"] ?? .null, requestID: nil)
        }
        let readOnly = #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"t","turnId":"u","itemId":"i","command":"/bin/zsh -lc 'git status --short && git log --oneline -5'"}}"#
        #expect(CodexEventMapper.autoApproval(for: try message(readOnly), mode: .askForRisky)?["decision"] == .string("accept"))
        #expect(CodexEventMapper.autoApproval(for: try message(readOnly), mode: .askForEverything) == nil)
        #expect(CodexEventMapper.autoApproval(for: try message(command), mode: .askForRisky) == nil)
        #expect(CodexEventMapper.autoApproval(for: try message(fileChange), mode: .askForRisky) == nil)
    }

    @Test func fileChangeDecisionsCoverEveryScope() throws {
        #expect(try decision(fileChange, .permission(.allowOnce)) == .string("accept"))
        #expect(try decision(fileChange, .permission(.allowForSession)) == .string("acceptForSession"))
        #expect(try decision(fileChange, .permission(.allowAlwaysInProject)) == .string("acceptForSession"))
        #expect(try decision(fileChange, .permission(.deny)) == .string("decline"))
    }

    @Test func permissionsGrantTheRequestedProfile() throws {
        var (mapper, ask) = try self.mapper(raising: permissions)
        let once = try mapper.reply(to: ask.id, with: .permission(.allowForSession))
        #expect(once.response.result == json(#"{"permissions":{"network":{"enabled":true}},"scope":"session"}"#))

        (mapper, ask) = try self.mapper(raising: permissions)
        let denied = try mapper.reply(to: ask.id, with: .permission(.deny))
        #expect(denied.response.result == json(#"{"permissions":{},"scope":"turn"}"#))
    }

    @Test func replyInWordsDeclinesAndSteers() throws {
        var (mapper, ask) = try self.mapper(raising: command)
        let reply = try mapper.reply(to: ask.id, with: .reply("Use pnpm instead"))
        #expect(reply.response.result["decision"] == .string("decline"))
        #expect(reply.followUp == "Use pnpm instead")
        #expect(throws: CodexEventMapper.AnswerError.unknownAsk("7")) { try mapper.reply(to: ask.id, with: .permission(.allowOnce)) }
    }

    @Test func secretQuestionsBecomeSecretAsks() throws {
        var (mapper, ask) = try self.mapper(raising: secret)
        #expect(ask.kind == .secret(SecretAsk(name: "STRIPE_KEY", reason: "Paste the Stripe key")))
        let reply = try mapper.reply(to: ask.id, with: .secret(value: "sk_test_123", saveForProject: false))
        #expect(reply.response.result == json(#"{"answers":{"stripe_key":{"answers":["sk_test_123"]}}}"#))
    }

    @Test func resolvedRequestsAreWithdrawn() throws {
        var (mapper, ask) = try self.mapper(raising: fileChange)
        let resolved = CodexServerMessage(method: "serverRequest/resolved", params: json(#"{"threadId":"t","requestId":8}"#))
        #expect(mapper.map(resolved) == [.askWithdrawn(askID: ask.id)])
        #expect(mapper.map(resolved) == [])
    }

    @Test func failedTurnsMapCodexErrorInfo() {
        var mapper = CodexEventMapper(sessionID: sessionID, workingDirectory: "/repo")
        let failed = CodexServerMessage(
            method: "turn/completed",
            params: json(#"{"threadId":"t","turn":{"id":"u","status":"failed","error":{"message":"You've hit your usage limit.","codexErrorInfo":"usageLimitExceeded"}}}"#)
        )
        #expect(mapper.map(failed) == [.failed(.usageLimit, message: "You've hit your usage limit.")])
        #expect(CodexEventMapper.failureReason(.string("unauthorized")) == .auth)
        #expect(CodexEventMapper.failureReason(json(#"{"httpConnectionFailed":{"httpStatusCode":502}}"#)) == .turnError)
    }

    @Test func anErrorOnlyDescribesItsOwnTurn() {
        var mapper = CodexEventMapper(sessionID: sessionID, workingDirectory: "/repo")
        func message(_ method: String, _ params: String) -> CodexServerMessage {
            CodexServerMessage(method: method, params: json(params))
        }
        _ = mapper.map(message("turn/started", #"{"threadId":"t","turn":{"id":"u1","status":"inProgress"}}"#))
        _ = mapper.map(message("error", #"{"threadId":"t","error":{"message":"stream disconnected"},"willRetry":false}"#))
        let systemError = message("thread/status/changed", #"{"threadId":"t","status":{"type":"systemError"}}"#)
        #expect(mapper.map(systemError) == [.failed(.turnError, message: "stream disconnected")])

        _ = mapper.map(message("turn/started", #"{"threadId":"t","turn":{"id":"u2","status":"inProgress"}}"#))
        let failed = message("turn/completed", #"{"threadId":"t","turn":{"id":"u2","status":"failed"}}"#)
        #expect(mapper.map(failed) == [.failed(.turnError, message: "The turn failed")])
    }

    @Test func pathsAreRelativeToTheWorktree() {
        let mapper = CodexEventMapper(sessionID: sessionID, workingDirectory: "/var/folders/x/repo")
        #expect(mapper.relativePath("/private/var/folders/x/repo/Sources/a.swift") == "Sources/a.swift")
        #expect(mapper.relativePath("/elsewhere/b.swift") == "/elsewhere/b.swift")
    }
}

// MARK: Helpers

private func json(_ text: String) -> CodexJSON {
    try! JSONDecoder().decode(CodexJSON.self, from: Data(text.utf8))
}

/// Reads events up to and including the first that matches, or until the stream pauses.
private func collect(
    _ events: inout AsyncStream<SessionEvent>.Iterator,
    until match: (SessionEvent) -> Bool
) async -> [SessionEvent] {
    var seen: [SessionEvent] = []
    while let event = await events.next() {
        seen.append(event)
        if match(event) { break }
    }
    return seen
}

private extension SessionEvent {
    var raisedAsk: Ask? {
        if case .askRaised(let ask) = self { ask } else { nil }
    }

    var isRunState: Bool {
        if case .runState = self { true } else { false }
    }
}
