import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct ClaudeCodeReplayTests {
    @Test func simpleTurnStreamsTextAndUsage() throws {
        let events = try ClaudeCodeFixture("simple").replay()
        #expect(events.finalTexts == ["hello"])
        #expect(events.contains(.assistantText("hello", isFinal: false)))
        #expect(events.contains { if case .usage(let usage) = $0 { usage.outputTokens == 21 && usage.costUSD == 0.0090667 } else { false } })
        #expect(events.failures.isEmpty)
        #expect(events.last == .exited(code: 0))
    }

    @Test func usageCountsOnlyWhatEachResultAdded() throws {
        let usages = try ClaudeCodeFixture("interrupt").replay().compactMap { event -> TokenUsage? in
            if case .usage(let usage) = event { usage } else { nil }
        }
        #expect(usages.count == 2)
        let total = usages.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(total - 0.00482104) < 0.000_000_1)
        #expect(usages.allSatisfy { $0.contextWindow == 1_000_000 })
    }

    @Test func resumedUsageLeavesOutEarlierProcesses() throws {
        let events = try ClaudeCodeFixture("resume").replay()
        guard case .usage(let usage)? = events.first(where: { if case .usage = $0 { true } else { false } }) else {
            Issue.record("expected a usage event")
            return
        }
        #expect(abs((usage.costUSD ?? 0) - 0.00342848) < 0.000_000_1)
        #expect(usage.inputTokens == 2 + 15648)
        #expect(usage.cachedInputTokens == 29668)
        #expect(usage.contextTokens == 2 + 15648 + 29668 + 4)
    }

    @Test func initWithAnotherSessionIDAnnouncesIt() throws {
        let fixture = try ClaudeCodeFixture("simple")
        var translator = ClaudeCodeTranslator(sessionID: UUID(), nativeID: "chosen-id", workingDirectory: ClaudeCodeFixture.workingDirectory)
        let events = fixture.replay(into: &translator)
        #expect(events.first == .started(nativeID: fixture.nativeID))
        #expect(translator.nativeID == fixture.nativeID)
    }

    @Test func bashPermissionBlocksThenFinishes() throws {
        let fixture = try ClaudeCodeFixture("bash")
        var translator = fixture.translator()
        let events = fixture.replay(into: &translator)

        #expect(events.runStates == ["working", "blocked", "working", "done"])
        let ask = try #require(events.asks.first)
        #expect(ask.sessionID == ClaudeCodeFixture.sessionID)
        guard case .permission(let permission) = ask.kind else { Issue.record("expected a permission ask"); return }
        #expect(permission.toolName == "Bash")
        #expect(permission.summary == "touch made-by-bash.txt")
        #expect(permission.inputPreview == "Create or update made-by-bash.txt in the working directory")
        #expect(permission.offeredDecisions == PermissionDecision.allCases)

        #expect(events.toolCalls.map(\.summary) == ["touch made-by-bash.txt"])
        #expect(events.toolResults.first?.isError == false)
    }

    @Test(arguments: [
        ("bash", AskAnswer.permission(.allowOnce)),
        ("bash-always", .permission(.allowAlwaysInProject)),
        ("bash-session", .permission(.allowForSession)),
        ("ask", .questions(["Which colour do you prefer?": ["Blue"]])),
        ("plan", .permission(.allowOnce)),
    ])
    func answersMatchWhatTheCLIAccepted(fixtureName: String, answer: AskAnswer) throws {
        let fixture = try ClaudeCodeFixture(fixtureName)
        var translator = fixture.translator()
        for entry in fixture.entries where entry.direction == "out" {
            let output = translator.handle(entry.frame)
            if let ask = output.events.asks.first {
                let reply = try translator.reply(to: ask.id, with: answer)
                #expect(reply == fixture.sentResponse(to: ask.id))
                #expect(!translator.pendingAskIDs.contains(ask.id))
                return
            }
        }
        Issue.record("no ask in \(fixtureName)")
    }

    @Test func askUserQuestionBecomesAQuestion() throws {
        let events = try ClaudeCodeFixture("ask").replay()
        let ask = try #require(events.asks.first)
        guard case .question(let question) = ask.kind else { Issue.record("expected a question"); return }
        let first = try #require(question.questions.first)
        #expect(first.id == "Which colour do you prefer?")
        #expect(first.header == "Colour")
        #expect(first.options.map(\.label) == ["Blue (Recommended)", "Red"])
        #expect(first.options.first?.description?.isEmpty == false)
        #expect(!first.multiSelect)
        #expect(events.runStates == ["working", "blocked", "working", "done"])
    }

    /// Without plan mode, a stray ExitPlanMode is asked like any other tool.
    @Test func exitPlanModeIsAnOrdinaryPermission() throws {
        let events = try ClaudeCodeFixture("plan").replay()
        guard case .permission(let permission) = events.asks.first?.kind else { Issue.record("expected a permission"); return }
        #expect(permission.toolName == "ExitPlanMode")
        #expect(permission.inputPreview?.contains("# Add a README") == true)
    }

    @Test func editPermissionsOfferEveryScope() throws {
        let fixture = try ClaudeCodeFixture("plan")
        var translator = fixture.translator()
        let writeAsk = try #require(fixture.replayUntilAsk(tool: "Write", into: &translator))

        guard case .permission(let permission) = writeAsk.kind else { Issue.record("expected permission"); return }
        #expect(permission.summary == "README.md")
        #expect(permission.inputPreview?.hasPrefix("# fixture-repo") == true)

        var sessionTranslator = translator
        let session = try sessionTranslator.reply(to: writeAsk.id, with: .permission(.allowForSession))
        #expect(session["response"]?["response"]?["updatedPermissions"] == [
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ])

        let always = try translator.reply(to: writeAsk.id, with: .permission(.allowAlwaysInProject))
        #expect(always["response"]?["response"]?["updatedPermissions"] == [
            ["type": "addRules", "rules": [["toolName": "Write"]], "behavior": "allow", "destination": "localSettings"],
        ])
    }

    @Test func filesTouchedComeFromWriteAndEdit() throws {
        let events = try ClaudeCodeFixture("edit").replay()
        #expect(events.toolCalls.map(\.name) == ["Write", "Edit"])
        #expect(events.toolCalls.flatMap(\.files) == ["notes.txt", "notes.txt"])
        #expect(events.toolCalls.first?.summary == "notes.txt")
        #expect(events.asks.isEmpty)
        #expect(events.runStates == ["working", "done"])
    }

    @Test func interruptEndsTheTurnWithoutFailing() throws {
        let events = try ClaudeCodeFixture("interrupt").replay()
        #expect(events.runStates == ["working", "interrupted", "working", "done"])
        #expect(events.failures.isEmpty)
        #expect(events.finalTexts.last == "ok")
    }

    @Test func interruptWhileBlockedWithdrawsTheAsk() throws {
        let events = try ClaudeCodeFixture("cancel").replay()
        let ask = try #require(events.asks.first)
        #expect(events.contains(.askWithdrawn(askID: ask.id)))
        #expect(events.runStates == ["working", "blocked", "working", "interrupted"])
        #expect(events.failures.isEmpty)
    }

    @Test func invalidCredentialsFailWithAuth() throws {
        let events = try ClaudeCodeFixture("authfail").replay()
        #expect(events.failures.map(\.0) == [.auth])
        #expect(events.failures.first?.1 == "Invalid API key · Fix external API key")
        #expect(events.runStates == ["working", "failed"])
        #expect(events.finalTexts.isEmpty)
    }

    @Test func resumedSessionKeepsItsID() throws {
        let fixture = try ClaudeCodeFixture("resume")
        #expect(fixture.nativeID == "213b2166-79ff-4ae9-90af-56e42117df99")
        let events = fixture.replay()
        #expect(!events.contains { if case .started = $0 { true } else { false } })
        #expect(events.finalTexts == ["hello"])
    }

    @Test func theHeadFollowsMainConversationMessagesAndIsReportedAtTheTurnEnd() {
        var translator = ClaudeCodeTranslator(sessionID: UUID(), nativeID: "n", workingDirectory: URL(filePath: "/tmp"))
        _ = translator.handle(["type": "assistant", "uuid": "a1", "parent_tool_use_id": nil, "message": ["content": []]])
        _ = translator.handle(["type": "assistant", "uuid": "sub", "parent_tool_use_id": "tool", "message": ["content": []]])
        _ = translator.handle(["type": "user", "uuid": "u2", "parent_tool_use_id": nil, "message": ["content": []]])
        #expect(translator.head == "u2")
        let output = translator.handle(["type": "result", "subtype": "success", "is_error": false])
        #expect(output.events == [.conversationHead("u2")])
    }

    @Test func outgoingFramesMatchTheCapture() throws {
        let fixture = try ClaudeCodeFixture("interrupt")
        let sent = fixture.outgoing
        #expect(sent.first == ClaudeCodeTranslator.userMessage("Count from 1 to 300, one number per line, no other text."))
        #expect(sent.contains(ClaudeCodeTranslator.controlRequest(id: "int-1", subtype: "interrupt")))
    }
}

@Suite struct ClaudeCodeTranslatorTests {
    var translator = ClaudeCodeTranslator(
        sessionID: UUID(),
        nativeID: "native",
        workingDirectory: URL(filePath: "/private/tmp/work")
    )

    @Test mutating func unsupportedControlRequestsGetAnErrorReply() {
        let output = translator.handle([
            "type": "control_request", "request_id": "r1",
            "request": ["subtype": "elicitation"],
        ])
        #expect(output.events.isEmpty)
        #expect(output.replies == [ClaudeCodeTranslator.controlError(requestID: "r1", message: "Unsupported control request: elicitation")])
    }

    @Test mutating func mismatchedAnswerThrowsAndKeepsTheAskPending() throws {
        _ = translator.handle(Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "make"]))
        #expect(throws: ProviderError.self) { try translator.reply(to: "r1", with: .secretDeclined) }
        #expect(translator.pendingAskIDs == ["r1"])
        #expect(throws: ProviderError.self) { try translator.reply(to: "unknown", with: .permission(.allowOnce)) }
    }

    @Test mutating func denyCarriesAMessage() throws {
        _ = translator.handle(Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "make"]))
        let reply = try translator.reply(to: "r1", with: .permission(.deny))
        #expect(reply["response"]?["response"]?["behavior"] == "deny")
        #expect(reply["response"]?["response"]?["message"]?.string?.isEmpty == false)
    }

    /// The reply goes in as the next user message, so the deny only declines and keeps the turn going.
    @Test mutating func aReplyDeclinesWithoutInterrupting() throws {
        _ = translator.handle(Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "make"]))
        let reply = try translator.reply(to: "r1", with: .reply("Run the tests instead."))
        #expect(reply["response"]?["response"] == [
            "behavior": "deny",
            "message": .string(ClaudeCodeTranslator.declinedForReply),
            "interrupt": false,
        ])
    }

    @Test mutating func readOnlyBashIsAllowedWithoutAskingUnderAskForRisky() {
        let output = translator.handle(Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "git status --short && ls"]))
        #expect(output.events.isEmpty)
        #expect(output.replies.first?["response"]?["request_id"] == "r1")
        #expect(output.replies.first?["response"]?["response"]?["behavior"] == "allow")
        #expect(translator.pendingAskIDs.isEmpty)

        #expect(translator.handle(Self.canUseTool(id: "r2", tool: "Bash", input: ["command": "python3 notes.py list"])).events.asks.count == 1)
        translator.permissionMode = .askForEverything
        #expect(translator.handle(Self.canUseTool(id: "r3", tool: "Bash", input: ["command": "ls"])).events.asks.count == 1)
    }

    @Test mutating func multiSelectAnswersAreJoined() throws {
        _ = translator.handle(Self.canUseTool(id: "q1", tool: "AskUserQuestion", input: [
            "questions": [["question": "Which?", "header": "Pick", "multiSelect": true, "options": [["label": "A"], ["label": "B"]]]],
        ]))
        let reply = try translator.reply(to: "q1", with: .questions(["Which?": ["A", "B"]]))
        #expect(reply["response"]?["response"]?["updatedInput"]?["answers"] == ["Which?": "A, B"])
    }

    @Test mutating func suppressedAlwaysRuleIsNotOffered() {
        var frame = Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "rm -rf build"])
        if case .object(var object) = frame, case .object(var request) = object["request"] {
            request["suppress_always_allow_rule"] = true
            object["request"] = .object(request)
            frame = .object(object)
        }
        guard case .permission(let permission) = translator.handle(frame).events.asks.first?.kind else {
            Issue.record("expected permission"); return
        }
        #expect(!permission.offeredDecisions.contains(.allowAlwaysInProject))
    }

    @Test mutating func editPreviewIsADiffAndPathsAreRelative() {
        let output = translator.handle(Self.canUseTool(id: "e1", tool: "Edit", input: [
            "file_path": "/tmp/work/Sources/App.swift", "old_string": "let a = 1", "new_string": "let a = 2",
        ]))
        guard case .permission(let permission) = output.events.asks.first?.kind else { Issue.record("expected permission"); return }
        #expect(permission.summary == "Sources/App.swift")
        #expect(permission.inputPreview == "- let a = 1\n+ let a = 2")
    }

    @Test mutating func secretToolResultsAreRedacted() {
        let call = translator.handle([
            "type": "assistant", "parent_tool_use_id": nil,
            "message": ["content": [[
                "type": "tool_use", "id": "t1", "name": .string(ClaudeCodeTranslator.secretToolName),
                "input": ["name": "STRIPE_KEY", "reason": "webhooks"],
            ]]],
        ])
        #expect(call.events.toolCalls.first?.summary == "mcp__constellation__request_secret")
        let result = translator.handle([
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "sk_live_123"]]],
        ])
        #expect(result.events.toolResults.first?.summary == "Secret provided (redacted)")
    }

    @Test mutating func subagentTextIsNotShown() {
        let output = translator.handle([
            "type": "assistant", "parent_tool_use_id": "toolu_parent",
            "message": ["content": [["type": "text", "text": "inner thoughts"]]],
        ])
        #expect(output.events.isEmpty)
    }

    @Test mutating func unexpectedExitFailsAndWithdrawsAsks() {
        _ = translator.handle(Self.canUseTool(id: "r1", tool: "Bash", input: ["command": "make"]))
        let events = translator.processExited(code: 1, stopRequested: false, stderrTail: ["boom", ""])
        #expect(events == [.askWithdrawn(askID: "r1"), .failed(.processExited, message: "boom"), .exited(code: 1)])
    }

    @Test mutating func aCrashAfterTheTurnSucceededOnlyExits() {
        _ = translator.handle(Self.state("running"))
        _ = translator.handle(Self.result(error: false))
        #expect(translator.processExited(code: 1, stopRequested: false, stderrTail: ["boom"]) == [.exited(code: 1)])
    }

    @Test mutating func aCrashWhileIdleOnlyExits() {
        _ = translator.handle(Self.state("running"))
        _ = translator.handle(Self.result(error: false))
        _ = translator.handle(Self.state("idle"))
        #expect(translator.processExited(code: 1, stopRequested: false, stderrTail: ["boom"]) == [.exited(code: 1)])
    }

    @Test mutating func aCrashMidTurnFails() {
        _ = translator.handle(Self.state("running"))
        let events = translator.processExited(code: 1, stopRequested: false, stderrTail: ["boom"])
        #expect(events == [.failed(.processExited, message: "boom"), .exited(code: 1)])
    }

    @Test mutating func anInterruptBetweenTurnsDoesNotCountAgainstTheNext() {
        _ = translator.handle(Self.state("running"))
        _ = translator.handle(Self.result(error: false))
        #expect(translator.handle(Self.state("idle")).events == [.runState(.done)])
        translator.noteInterruptRequested()
        translator.noteMessageSent()
        _ = translator.handle(Self.state("running"))
        let events = translator.handle(Self.result(error: true)).events
        #expect(events == [.failed(.turnError, message: "overloaded")])
    }

    @Test mutating func anInterruptBeforeTheCLIReportsRunningStillCounts() {
        translator.noteMessageSent()
        translator.noteInterruptRequested()
        _ = translator.handle(Self.state("running"))
        #expect(translator.handle(Self.result(error: true)).events == [.interrupted])
        #expect(translator.handle(Self.state("idle")).events.isEmpty)
    }

    @Test mutating func anAPIErrorOnlyNamesItsOwnTurn() {
        _ = translator.handle(Self.state("running"))
        _ = translator.handle(["type": "assistant", "error": "rate_limit", "message": ["content": []]])
        #expect(translator.handle(Self.result(error: true)).events == [.failed(.usageLimit, message: "overloaded")])
        _ = translator.handle(Self.state("idle"))
        _ = translator.handle(Self.state("running"))
        #expect(translator.handle(Self.result(error: true)).events == [.failed(.turnError, message: "overloaded")])
    }

    static func state(_ state: String) -> JSONValue {
        ["type": "system", "subtype": "session_state_changed", "state": .string(state)]
    }

    static func result(error: Bool) -> JSONValue {
        error
            ? ["type": "result", "subtype": "error_during_execution", "is_error": true, "result": "overloaded"]
            : ["type": "result", "subtype": "success", "is_error": false]
    }

    @Test func failureReasons() {
        #expect(ClaudeCodeTranslator.failureReason(apiError: "rate_limit", status: nil) == .usageLimit)
        #expect(ClaudeCodeTranslator.failureReason(apiError: nil, status: 429) == .usageLimit)
        #expect(ClaudeCodeTranslator.failureReason(apiError: "authentication_failed", status: 401) == .auth)
        #expect(ClaudeCodeTranslator.failureReason(apiError: nil, status: 500) == .turnError)
    }

    static func canUseTool(id: String, tool: String, input: JSONValue) -> JSONValue {
        [
            "type": "control_request", "request_id": .string(id),
            "request": ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input, "tool_use_id": "toolu_1"],
        ]
    }
}

extension ClaudeCodeFixture {
    func replayUntilAsk(tool: String, into translator: inout ClaudeCodeTranslator) -> Ask? {
        for entry in entries where entry.direction == "out" {
            let output = translator.handle(entry.frame)
            if let ask = output.events.asks.first {
                if case .permission(let permission) = ask.kind, permission.toolName == tool { return ask }
                // Answer earlier asks as the capture did, so later frames line up.
                _ = try? translator.reply(to: ask.id, with: .permission(.allowOnce))
            }
        }
        return nil
    }
}
