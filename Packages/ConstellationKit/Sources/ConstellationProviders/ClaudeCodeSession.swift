import ConstellationCore
import Foundation

/// One running `claude -p --input-format stream-json` process, driven over stdio.
public actor ClaudeCodeSession: TurnSettingsAdjustable {
    public nonisolated let sessionID: UUID
    public nonisolated let events: AsyncStream<SessionEvent>

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let process: JSONLineProcess
    private var translator: ClaudeCodeTranslator
    private var stopRequested = false
    private var nextRequestNumber = 1
    private let stopGracePeriod: Duration
    /// What the CLI runs with now, and what the next message should run with.
    private(set) var appliedSettings: TurnSettings
    private var wantedSettings: TurnSettings
    private var controlReplies: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private var refused: [String] = []

    init(
        executable: URL,
        launch: SessionLaunch,
        nativeID: String,
        environment: [String: String],
        stopGracePeriod: Duration = .seconds(3)
    ) throws {
        sessionID = launch.sessionID
        self.stopGracePeriod = stopGracePeriod
        appliedSettings = launch.turnSettings
        wantedSettings = launch.turnSettings
        (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self, bufferingPolicy: .unbounded)
        translator = ClaudeCodeTranslator(sessionID: launch.sessionID, nativeID: nativeID, workingDirectory: launch.workingDirectory)
        translator.permissionMode = launch.permissionMode
        process = try JSONLineProcess(
            executable: executable,
            arguments: try Self.arguments(for: launch, nativeID: nativeID),
            environment: environment,
            currentDirectory: launch.workingDirectory
        )
    }

    /// Starts reading output and sends the first message, if any.
    func begin(message: UserMessage?) async throws {
        continuation.yield(.started(nativeID: translator.nativeID))
        Task { await self.pump() }
        if let message, !message.isEmpty { try await send(message) }
    }

    /// Mid-turn, the CLI queues the message and reads it once the current step finishes. Settings
    /// changed since the last message are applied first.
    public func send(_ message: UserMessage) async throws {
        await applyWantedSettings()
        let uuid = UUID().uuidString.lowercased()
        let frame: JSONValue
        do {
            frame = try ClaudeCodeTranslator.userMessage(message, uuid: uuid)
        } catch {
            throw ProviderError.protocolViolation("Could not read an attachment: \(error.localizedDescription)")
        }
        let resumeAt = translator.head
        try write(frame)
        translator.noteMessageSent()
        continuation.yield(.userMessage(message.text, attachments: message.attachments.isEmpty ? nil : message.attachments))
        continuation.yield(.checkpoint(Checkpoint(turnID: uuid, resumeAt: resumeAt)))
    }

    public func adjust(_ settings: TurnSettings) {
        wantedSettings = settings
    }

    public func takeRefusal() -> SettingsRefusal? {
        guard !refused.isEmpty else { return nil }
        defer { refused = [] }
        return SettingsRefusal(applied: appliedSettings, message: "Claude Code refused the new \(refused.joined(separator: " and ")), so it keeps the current one")
    }

    /// `set_model`, `apply_flag_settings` for effort and `set_permission_mode`, each only when it
    /// changed. A refused change is dropped and reported
    /// through ``takeRefusal()``.
    private func applyWantedSettings() async {
        let (wanted, applied) = (wantedSettings, appliedSettings)
        if wanted.model != applied.model {
            if await control("set_model", ["model": .string(wanted.model)]) {
                appliedSettings.model = wanted.model
            } else {
                refuse("model")
                wantedSettings.model = applied.model
            }
        }
        if wanted.effort != applied.effort, let effort = wanted.effort {
            if await control("apply_flag_settings", ["settings": ["effortLevel": .string(effort)]]) {
                appliedSettings.effort = effort
            } else {
                refuse("effort")
                wantedSettings.effort = applied.effort
            }
        }
        if wanted.permissionMode != applied.permissionMode {
            let mode = ClaudeCodeAdapter.permissionModeArgument(for: wanted.permissionMode)
            if await control("set_permission_mode", ["mode": .string(mode)]) {
                appliedSettings.permissionMode = wanted.permissionMode
                translator.permissionMode = wanted.permissionMode
            } else {
                refuse("permission mode")
                wantedSettings.permissionMode = applied.permissionMode
            }
        }
    }

    private func refuse(_ setting: String) {
        if !refused.contains(setting) { refused.append(setting) }
    }

    /// Sends a control request and waits up to ten seconds for its reply. True on success.
    private func control(_ subtype: String, _ fields: [String: JSONValue]) async -> Bool {
        let id = nextRequestID(subtype)
        do {
            try write(ClaudeCodeTranslator.controlRequest(id: id, subtype: subtype, fields))
        } catch {
            return false
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            self.resolveControl(id, with: nil)
        }
        defer { timeout.cancel() }
        let reply = await withCheckedContinuation { controlReplies[id] = $0 }
        return reply?["subtype"]?.string == "success"
    }

    private func resolveControl(_ id: String, with response: JSONValue?) {
        controlReplies.removeValue(forKey: id)?.resume(returning: response)
    }

    /// A reply declines the ask, then goes in as the user's next message.
    public func answer(ask: Ask, with answer: AskAnswer) async throws {
        try write(translator.reply(to: ask.id, with: answer))
        if case .reply(let text) = answer { try await send(UserMessage(text: text)) }
    }

    /// Ends the current turn. Pending asks are withdrawn by the CLI with `control_cancel_request`.
    public func interrupt() async throws {
        translator.noteInterruptRequested()
        try write(ClaudeCodeTranslator.controlRequest(id: nextRequestID("interrupt"), subtype: "interrupt"))
    }

    /// Closes stdin, then sends SIGTERM after a grace period, and SIGKILL if that is ignored too,
    /// each to the whole process group. What is left of the group gets SIGTERM once Claude exits.
    public func stop() async {
        stopRequested = true
        process.closeInput()
        for signal in [SIGTERM, SIGKILL] {
            if await process.waitForExit(timeout: stopGracePeriod) != nil { return }
            process.signalGroup(signal)
        }
    }

    private func pump() async {
        for await line in process.lines {
            guard let frame = try? JSONValue.decode(line) else { continue }
            if frame["type"]?.string == "control_response", let id = frame["response"]?["request_id"]?.string, controlReplies[id] != nil {
                resolveControl(id, with: frame["response"])
                continue
            }
            let output = translator.handle(frame)
            for event in output.events { continuation.yield(event) }
            for reply in output.replies { try? write(reply) }
        }
        for id in controlReplies.keys { resolveControl(id, with: nil) }
        let code = await process.waitForExit()
        let events = translator.processExited(code: code, stopRequested: stopRequested, stderrTail: process.stderrTail)
        for event in events { continuation.yield(event) }
        continuation.finish()
    }

    private func write(_ frame: JSONValue) throws {
        do {
            try process.write(frame.encoded())
        } catch {
            throw ProviderError.protocolViolation("Could not write to Claude Code: \(error.localizedDescription)")
        }
    }

    private func nextRequestID(_ prefix: String) -> String {
        defer { nextRequestNumber += 1 }
        return "constellation-\(prefix)-\(nextRequestNumber)"
    }

    static func arguments(for launch: SessionLaunch, nativeID: String) throws -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--mcp-config", try mcpConfigJSON(launch.mcpServer),
            "--allowedTools", MCPServerConfig.claudeAllowedTools.joined(separator: ","),
            "--settings", try flagSettingsJSON(launch.permissionMode),
            // Only makes Full auto reachable mid-session; the session starts in --permission-mode.
            "--allow-dangerously-skip-permissions",
            "--model", launch.model,
            "--permission-mode", ClaudeCodeAdapter.permissionModeArgument(for: launch.permissionMode),
        ]
        if let effort = launch.effort { arguments += ["--effort", effort] }
        if let instructions = launch.instructions { arguments += ["--append-system-prompt", instructions] }
        switch (launch.resumeID, launch.cut) {
        case (let source?, .fork(let through)?):
            // A fork gets its own id up front, so a restart before its first message resumes the fork.
            arguments += ["--resume", source, "--fork-session", "--session-id", nativeID]
            if let through { arguments += ["--resume-session-at", through] }
        case (let resumeID?, .rewind(let before?)?):
            arguments += ["--resume", resumeID, "--resume-session-at", before]
        case (let resumeID?, nil):
            arguments += ["--resume", resumeID]
        case (_, .rewind(before: nil)?), (nil, _):
            arguments += ["--session-id", nativeID]
        }
        return arguments
    }

    /// Flag settings outrank the user's own, so their `defaultMode` (say "auto") can't widen the
    /// session's mode, and auto mode's classifier can't approve what Constellation should ask about.
    static func flagSettingsJSON(_ mode: PermissionMode) throws -> String {
        let settings: JSONValue = [
            "permissions": [
                "defaultMode": .string(ClaudeCodeAdapter.permissionModeArgument(for: mode)),
                "disableAutoMode": "disable",
            ],
        ]
        return String(decoding: try settings.encoded(), as: UTF8.self)
    }

    /// Inline `--mcp-config` JSON that launches the Constellation MCP server over stdio.
    static func mcpConfigJSON(_ server: MCPServerConfig) throws -> String {
        let config: JSONValue = [
            "mcpServers": [
                MCPServerConfig.serverName: [
                    "type": "stdio",
                    "command": .string(server.command.path(percentEncoded: false)),
                    "args": .array(server.arguments.map(JSONValue.string)),
                    "env": .object(server.environment.mapValues(JSONValue.string)),
                ],
            ],
        ]
        return String(decoding: try config.encoded(), as: UTF8.self)
    }
}
