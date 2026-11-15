import ConstellationCore
import Foundation

/// One shared `codex app-server` process for every Codex session.
public actor CodexAdapter: ProviderAdapter, ModelCatalog {
    public nonisolated let provider = Provider.codex

    private let makeTransport: @Sendable () async throws -> any CodexTransport
    private var server: CodexAppServer?
    private var launching: Task<CodexAppServer, any Error>?

    /// - Parameter executable: the `codex` binary; found with `locator` when nil.
    public init(locator: BinaryLocator = .shared, executable: URL? = nil) {
        makeTransport = {
            let binary: URL
            if let executable {
                binary = executable
            } else {
                binary = try await locator.locate("codex")
            }
            return try CodexProcess(executable: binary, arguments: ["app-server"], environment: Self.environment(for: binary))
        }
    }

    init(transport: @escaping @Sendable () async throws -> any CodexTransport) {
        makeTransport = transport
    }

    public func start(_ launch: SessionLaunch) async throws -> any ProviderSessionHandle {
        let server = try await sharedServer()
        let (approvalPolicy, sandbox) = Self.policy(for: launch.permissionMode)
        let cwd = launch.workingDirectory.path(percentEncoded: false)
        let model = launch.model.isEmpty ? nil : launch.model
        let config = Self.config(for: launch)

        let response: CodexThreadResponse
        if let threadID = launch.resumeID, case .fork(let through)? = launch.cut {
            let params = CodexThreadForkParams(
                threadId: threadID, lastTurnId: through, cwd: cwd, model: model,
                approvalPolicy: approvalPolicy, sandbox: sandbox, config: config
            )
            response = try await server.request(CodexMethod.threadFork, params)
        } else if let threadID = launch.resumeID {
            let params = CodexThreadResumeParams(
                threadId: threadID, cwd: cwd, model: model,
                approvalPolicy: approvalPolicy, sandbox: sandbox, config: config
            )
            response = try await server.request(CodexMethod.threadResume, params)
            // The thread has to be loaded in this app-server to revert it, which the resume does.
            if case .rewind(let before?)? = launch.cut {
                let revert = CodexThreadRevertParams(threadId: threadID, beforeTurnId: before)
                _ = try await server.request(CodexMethod.threadRevert, revert, as: CodexJSON.self)
            }
        } else {
            let params = CodexThreadStartParams(
                cwd: cwd, model: model,
                approvalPolicy: approvalPolicy, sandbox: sandbox, config: config
            )
            response = try await server.request(CodexMethod.threadStart, params)
        }

        let handle = CodexSessionHandle(
            sessionID: launch.sessionID,
            threadID: response.thread.id,
            model: response.model ?? launch.model,
            settings: launch.turnSettings,
            workingDirectory: cwd,
            server: server
        )
        try await handle.begin(message: launch.message)
        return handle
    }

    /// `model/list`, with the app-server's own default first as the empty model.
    public func models() async throws -> [ModelChoice] {
        let server = try await sharedServer()
        var models: [CodexModelListResponse.Model] = []
        var cursor: String?
        repeat {
            let page: CodexModelListResponse = try await server.request(CodexMethod.modelList, CodexModelListParams(cursor: cursor))
            models += page.data
            cursor = page.nextCursor
        } while cursor != nil && models.count < 200
        let choices = models.filter { !$0.hidden }.map { model in
            ModelChoice(
                id: model.model,
                title: model.displayName,
                efforts: model.supportedReasoningEfforts.map(\.reasoningEffort),
                defaultEffort: model.defaultReasoningEffort,
                supportsFastMode: !(model.serviceTiers ?? []).isEmpty
            )
        }
        guard let fallback = models.first(where: \.isDefault).flatMap({ model in choices.first { $0.id == model.model } }) else {
            return choices
        }
        var automatic = fallback
        automatic.id = ""
        automatic.title = "Default (\(fallback.title))"
        return [automatic] + choices
    }

    /// The skills Codex offers in `directory`, from `skills/list`, for the composer's `/` menu.
    public func skills(in directory: URL) async throws -> [SlashCommand] {
        try await Self.skills(in: directory.path(percentEncoded: false), server: try await sharedServer())
    }

    static func skills(in cwd: String, server: CodexAppServer) async throws -> [SlashCommand] {
        let response = try await server.request(CodexMethod.skillsList, CodexSkillsListParams(cwds: [cwd]), as: CodexSkillsListResponse.self)
        return response.commands(for: cwd)
    }

    /// Stops the shared app-server. Running sessions see it exit.
    public func shutdown() async {
        let current = server
        server = nil
        launching = nil
        await current?.close()
    }

    /// The Codex `approvalPolicy` and `sandbox` for a Constellation permission mode.
    public static func policy(for mode: PermissionMode) -> (approvalPolicy: String, sandbox: String) {
        switch mode {
        case .askForEverything: ("untrusted", "read-only")
        case .askForRisky: ("on-request", "workspace-write")
        case .fullAuto: ("never", "danger-full-access")
        }
    }

    static func config(for launch: SessionLaunch) -> CodexThreadConfig {
        let mcp = launch.mcpServer
        return CodexThreadConfig(
            mcpServers: [
                MCPServerConfig.serverName: .init(
                    command: mcp.command.path(percentEncoded: false),
                    args: mcp.arguments,
                    env: mcp.environment
                ),
            ],
            shellEnvironmentPolicy: launch.environment.isEmpty ? nil : .init(set: launch.environment),
            developerInstructions: launch.instructions
        )
    }

    /// The app's environment with the binary's directory on `PATH`, since a GUI app inherits a bare `PATH`
    /// and `codex` is often a Node script that needs `node` from the same place.
    static func environment(for binary: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directories = [binary.deletingLastPathComponent().path(percentEncoded: false), "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = environment["PATH"].map { [$0] } ?? ["/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = (directories + existing).joined(separator: ":")
        return environment
    }

    private func sharedServer() async throws -> CodexAppServer {
        if let server, await !server.isClosed { return server }
        if let launching { return try await launching.value }
        let task = Task { [makeTransport] in
            let server = CodexAppServer(transport: try await makeTransport())
            try await server.start()
            return server
        }
        launching = task
        defer { launching = nil }
        let started = try await task.value
        server = started
        return started
    }
}

/// One Codex thread, driven over the shared app-server.
actor CodexSessionHandle: TurnSettingsAdjustable {
    /// The service tier `model/list` offers every current model for fast mode.
    static let fastServiceTier = "priority"

    nonisolated let sessionID: UUID
    nonisolated let events: AsyncStream<SessionEvent>
    nonisolated let threadID: String

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let server: CodexAppServer
    private let model: String
    private let workingDirectory: String
    private var mapper: CodexEventMapper
    private var pump: Task<Void, Never>?
    private var stopped = false
    private var settings: TurnSettings
    /// The permission mode the thread started or last turned with, and whether a service tier was set.
    private var appliedPermissionMode: PermissionMode
    private var sentServiceTier = false

    init(sessionID: UUID, threadID: String, model: String, settings: TurnSettings, workingDirectory: String, server: CodexAppServer) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.model = model
        self.settings = settings
        appliedPermissionMode = settings.permissionMode
        self.workingDirectory = workingDirectory
        self.server = server
        self.mapper = CodexEventMapper(sessionID: sessionID, workingDirectory: workingDirectory)
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    func begin(message: UserMessage?) async throws {
        let stream = await server.subscribe(threadID: threadID)
        continuation.yield(.started(nativeID: threadID))
        pump = Task {
            for await event in stream {
                await self.handle(event)
            }
        }
        if let message, !message.isEmpty {
            try await send(message)
        }
    }

    /// Steers the active turn, or starts one. The message is recorded here rather than from Codex's
    /// echoed `userMessage` item, which carries the paths added for attachments instead of your words.
    func send(_ message: UserMessage) async throws {
        let turnID = try await deliver(message)
        continuation.yield(.userMessage(message.text, attachments: message.attachments.isEmpty ? nil : message.attachments))
        if let turnID { continuation.yield(.checkpoint(Checkpoint(turnID: turnID))) }
    }

    func adjust(_ settings: TurnSettings) {
        self.settings = settings
    }

    /// Codex takes settings with each turn, so none are refused up front.
    func takeRefusal() -> SettingsRefusal? { nil }

    /// The id of the turn the message started, or nil when it steered the running one.
    private func deliver(_ message: UserMessage) async throws -> String? {
        var skills: [SlashCommand] = []
        if !SlashCommand.codexSkillMentions(in: message.text).isEmpty {
            // Unknown `$words` stay plain text, so a failed lookup only loses the skill items.
            skills = (try? await CodexAdapter.skills(in: workingDirectory, server: server)) ?? []
        }
        let input = CodexUserInput.items(for: message, skills: skills)
        if let turnID = mapper.activeTurnID {
            let params = CodexTurnSteerParams(threadId: threadID, expectedTurnId: turnID, input: input)
            do {
                _ = try await server.request(CodexMethod.turnSteer, params, as: CodexJSON.self)
                return nil
            } catch is CodexRPCError {
                // The turn ended before the steer arrived. Start a new one instead.
            }
        }
        return try await startTurn(input)
    }

    func answer(ask: Ask, with answer: AskAnswer) async throws {
        let reply = try mapper.reply(to: ask.id, with: answer)
        try await server.respond(to: reply.response.id, result: reply.response.result)
        if let text = reply.followUp { try await send(userMessage: text) }
    }

    func interrupt() async throws {
        guard let turnID = mapper.activeTurnID else { return }
        _ = try await server.request(CodexMethod.turnInterrupt, CodexTurnInterruptParams(threadId: threadID, turnId: turnID), as: CodexJSON.self)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        if mapper.activeTurnID != nil {
            try? await interrupt()
            continuation.yield(.interrupted)
        }
        _ = try? await server.request(CodexMethod.threadUnsubscribe, CodexThreadIDParams(threadId: threadID), as: CodexJSON.self)
        await server.unsubscribe(threadID: threadID)
        pump?.cancel()
        continuation.finish()
    }

    /// Sends the settings with every turn, as T3 Code does: the default collaboration mode always (so
    /// a thread left in plan mode leaves it), policies and the service tier once they differ from the thread's.
    private func startTurn(_ input: [CodexUserInput]) async throws -> String {
        let params = turnStartParams(input)
        let response = try await server.request(CodexMethod.turnStart, params, as: CodexTurnResponse.self)
        if params.approvalPolicy != nil { appliedPermissionMode = settings.permissionMode }
        if params.serviceTier != nil { sentServiceTier = settings.fastMode }
        mapper.turnStarted(response.turn.id)
        return response.turn.id
    }

    func turnStartParams(_ input: [CodexUserInput]) -> CodexTurnStartParams {
        let model = settings.model.isEmpty ? self.model : settings.model
        var params = CodexTurnStartParams(
            threadId: threadID,
            input: input,
            collaborationMode: CodexCollaborationMode(settings: .init(model: model, reasoningEffort: settings.effort)),
            model: settings.model.isEmpty ? nil : settings.model,
            effort: settings.effort
        )
        if settings.fastMode || sentServiceTier {
            params.serviceTier = settings.fastMode ? Self.fastServiceTier : "default"
        }
        if settings.permissionMode != appliedPermissionMode {
            let (approvalPolicy, sandbox) = CodexAdapter.policy(for: settings.permissionMode)
            params.approvalPolicy = approvalPolicy
            params.sandboxPolicy = CodexSandboxPolicy(sandbox: sandbox)
        }
        return params
    }

    private func handle(_ event: CodexThreadEvent) async {
        guard !stopped else { return }
        switch event {
        case .message(let message):
            if let id = message.requestID, let result = CodexEventMapper.autoApproval(for: message, mode: appliedPermissionMode) {
                try? await server.respond(to: id, result: result)
                return
            }
            for event in mapper.map(message) { continuation.yield(event) }
        case .serverClosed(let code):
            // Only a session with work in flight failed; a finished one just lost its process.
            if mapper.activeTurnID != nil || mapper.hasPendingAsks {
                continuation.yield(.failed(.processExited, message: "codex app-server exited"))
            }
            continuation.yield(.exited(code: code ?? -1))
            continuation.finish()
        }
    }
}
