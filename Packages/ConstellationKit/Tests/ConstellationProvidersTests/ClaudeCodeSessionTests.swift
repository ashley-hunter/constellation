import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct ClaudeCodeSessionTests {
    static let mcpServer = MCPServerConfig(
        command: URL(filePath: "/Applications/Constellation.app/Contents/Helpers/constellation-mcp"),
        environment: ["CONSTELLATION_SESSION_ID": "abc"]
    )

    @Test func argumentsForANewSession() throws {
        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: URL(filePath: "/tmp/w"), model: "sonnet",
            permissionMode: .askForRisky, prompt: "hi", mcpServer: Self.mcpServer
        )
        let arguments = try ClaudeCodeSession.arguments(for: launch, nativeID: "native-1")
        #expect(arguments.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.joined(separator: " ").contains("--permission-prompt-tool stdio"))
        #expect(arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(arguments.joined(separator: " ").contains("--model sonnet --permission-mode acceptEdits"))
        #expect(arguments.suffix(2) == ["--session-id", "native-1"])
        #expect(arguments.joined(separator: " ").contains(
            "--allowedTools mcp__constellation__request_secret,mcp__constellation__report_outcome"
        ))

        let configIndex = try #require(arguments.firstIndex(of: "--mcp-config"))
        let config = try JSONValue.decode(Data(arguments[configIndex + 1].utf8))
        #expect(config["mcpServers"]?["constellation"] == [
            "type": "stdio",
            "command": "/Applications/Constellation.app/Contents/Helpers/constellation-mcp",
            "args": [],
            "env": ["CONSTELLATION_SESSION_ID": "abc"],
        ])

        // Flag settings pin the mode over a user's own defaultMode.
        let settingsIndex = try #require(arguments.firstIndex(of: "--settings"))
        let settings = try JSONValue.decode(Data(arguments[settingsIndex + 1].utf8))
        #expect(settings == ["permissions": ["defaultMode": "acceptEdits", "disableAutoMode": "disable"]])
    }

    /// A reply to a permission declines it, then goes in as the user's next message.
    @Test func aReplyDeclinesThenSendsTheMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "claude")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")"
        printf '%s\\n' '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm test"}}}'
        read -r line; printf '%s\\n' "$line" >> received
        read -r line; printf '%s\\n' "$line" >> received
        while read -r line; do :; done
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: directory, model: "sonnet",
            permissionMode: .askForEverything, prompt: nil, mcpServer: Self.mcpServer
        )
        let session = try ClaudeCodeSession(executable: script, launch: launch, nativeID: "n", environment: [:])
        try await session.begin(message: nil)
        var events: [SessionEvent] = []
        for await event in session.events {
            events.append(event)
            if case .askRaised(let ask) = event {
                try await session.answer(ask: ask, with: .reply("Don't, just say ok."))
                await session.stop()
            }
        }

        let lines = try String(contentsOf: directory.appending(path: "received"), encoding: .utf8)
            .split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        #expect(lines.count == 2)
        #expect(lines.first?["response"]?["response"]?["behavior"] == "deny")
        #expect(lines.first?["response"]?["response"]?["interrupt"] == false)
        #expect(lines.last?["type"] == "user")
        #expect(lines.last?["message"]?["content"] == "Don't, just say ok.")
        #expect(events.contains(.userMessage("Don't, just say ok.")))
    }

    @Test func instructionsAppendToTheSystemPrompt() throws {
        var launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: URL(filePath: "/tmp/w"), model: "sonnet",
            permissionMode: .askForRisky, prompt: "What does this do?", mcpServer: Self.mcpServer
        )
        #expect(try !ClaudeCodeSession.arguments(for: launch, nativeID: "n").contains("--append-system-prompt"))
        launch.instructions = "Answer only."
        #expect(try ClaudeCodeSession.arguments(for: launch, nativeID: "n").joined(separator: " ").contains("--append-system-prompt Answer only."))
    }

    @Test func argumentsForAResumedSession() throws {
        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: URL(filePath: "/tmp/w"), model: "opus",
            permissionMode: .fullAuto, prompt: nil, mcpServer: Self.mcpServer, resumeID: "old-id"
        )
        let arguments = try ClaudeCodeSession.arguments(for: launch, nativeID: "old-id")
        #expect(arguments.suffix(2) == ["--resume", "old-id"])
        #expect(!arguments.contains("--session-id"))
        #expect(arguments.contains("bypassPermissions"))
    }

    @Test func argumentsForAForkAndARewind() throws {
        var launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: URL(filePath: "/tmp/w"), model: "haiku",
            permissionMode: .askForRisky, prompt: nil, mcpServer: Self.mcpServer, resumeID: "source"
        )
        launch.effort = "low"
        launch.cut = .fork(through: "msg-3")
        #expect(!ClaudeCodeAdapter.keepsNativeID(launch))
        var arguments = try ClaudeCodeSession.arguments(for: launch, nativeID: "fork-id")
        #expect(arguments.joined(separator: " ").contains("--permission-mode acceptEdits --effort low"))
        #expect(Array(arguments.suffix(7)) == ["--resume", "source", "--fork-session", "--session-id", "fork-id", "--resume-session-at", "msg-3"])

        launch.cut = .rewind(before: "msg-2")
        #expect(ClaudeCodeAdapter.keepsNativeID(launch))
        arguments = try ClaudeCodeSession.arguments(for: launch, nativeID: "source")
        #expect(Array(arguments.suffix(4)) == ["--resume", "source", "--resume-session-at", "msg-2"])

        // Back to before the first message: a fresh conversation.
        launch.cut = .rewind(before: nil)
        #expect(!ClaudeCodeAdapter.keepsNativeID(launch))
        arguments = try ClaudeCodeSession.arguments(for: launch, nativeID: "fresh")
        #expect(Array(arguments.suffix(2)) == ["--session-id", "fresh"])
        #expect(!arguments.contains("--resume"))
    }

    @Test func environmentUsesTheShellPathAndEnablesStateEvents() {
        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: URL(filePath: "/tmp/w"), model: "m",
            permissionMode: .default, prompt: nil, environment: ["STRIPE_KEY": "s"], mcpServer: Self.mcpServer
        )
        let environment = ClaudeCodeAdapter.environment(for: launch, searchPath: "/a:/b", base: ["PATH": "/usr/bin", "HOME": "/h"])
        #expect(environment == [
            "PATH": "/a:/b", "HOME": "/h", "STRIPE_KEY": "s", "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS": "1",
        ])
    }

    /// Runs a session against a stand-in `claude` that replays the captured Bash permission frames.
    @Test func permissionRoundTripThroughAFakeCLI() async throws {
        let fixture = try ClaudeCodeFixture("bash")
        let directory = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let out = fixture.entries.filter { $0.direction == "out" }.map(\.frame)
        let split = try #require(out.firstIndex { $0["type"]?.string == "control_request" }) + 1
        func write(_ frames: some Sequence<JSONValue>, to name: String) throws {
            let text = try frames.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: directory.appending(path: name))
        }
        try write(out[..<split], to: "part1.jsonl")
        try write(out[split...], to: "part2.jsonl")

        let script = directory.appending(path: "claude")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")"
        printf '%s\\n' "$@" > args
        printf '%s' "$CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS" > env
        read -r line; printf '%s\\n' "$line" > received-1
        cat part1.jsonl
        read -r line; printf '%s\\n' "$line" > received-2
        cat part2.jsonl
        while read -r line; do :; done
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let prompt = "Use the Bash tool to run exactly: touch made-by-bash.txt . Then say done."
        let launch = SessionLaunch(
            sessionID: ClaudeCodeFixture.sessionID, workingDirectory: directory, model: "haiku",
            permissionMode: .askForEverything, prompt: prompt, mcpServer: Self.mcpServer
        )
        let session = try ClaudeCodeSession(
            executable: script, launch: launch, nativeID: fixture.nativeID,
            environment: ClaudeCodeAdapter.environment(for: launch, searchPath: "/usr/bin:/bin")
        )
        try await session.begin(message: UserMessage(text: prompt))

        var events: [SessionEvent] = []
        var answeredAsk: Ask?
        for await event in session.events {
            events.append(event)
            if case .askRaised(let ask) = event {
                answeredAsk = ask
                try await session.answer(ask: ask, with: .permission(.allowOnce))
            }
            if event == .runState(.done) { await session.stop() }
        }

        #expect(events.prefix(2) == [.started(nativeID: fixture.nativeID), .userMessage(prompt)])
        #expect(events.runStates == ["working", "blocked", "working", "done"])
        #expect(events.last == .exited(code: 0))

        let ask = try #require(answeredAsk)
        let first = try JSONValue.decode(Data(contentsOf: directory.appending(path: "received-1")))
        let second = try JSONValue.decode(Data(contentsOf: directory.appending(path: "received-2")))
        let uuid = try #require(first["uuid"]?.string)
        #expect(first == ClaudeCodeTranslator.userMessage(prompt, uuid: uuid))
        #expect(events.contains(.checkpoint(Checkpoint(turnID: uuid))))
        #expect(events.contains { if case .conversationHead = $0 { true } else { false } })
        #expect(second == fixture.sentResponse(to: ask.id))
        #expect(try String(contentsOf: directory.appending(path: "env"), encoding: .utf8) == "1")
        #expect(try String(contentsOf: directory.appending(path: "args"), encoding: .utf8).contains("--permission-prompt-tool\nstdio\n"))
    }

    /// Changed settings go out as control requests, each answered, before the next message.
    @Test func settingsApplyBeforeTheNextMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "claude")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")"
        reply() { printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s"}}\\n' "$1"; }
        read -r line; printf '%s\\n' "$line" >> received; reply constellation-set_model-1
        read -r line; printf '%s\\n' "$line" >> received; reply constellation-apply_flag_settings-2
        read -r line; printf '%s\\n' "$line" >> received; reply constellation-set_permission_mode-3
        read -r line; printf '%s\\n' "$line" >> received
        while read -r line; do :; done
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: directory, model: "sonnet",
            permissionMode: .askForRisky, prompt: nil, mcpServer: Self.mcpServer
        )
        let session = try ClaudeCodeSession(executable: script, launch: launch, nativeID: "n", environment: [:])
        try await session.begin(message: nil)
        await session.adjust(TurnSettings(model: "haiku", effort: "low", permissionMode: .fullAuto))
        try await session.send(UserMessage(text: "go"))
        await session.stop()

        let lines = try String(contentsOf: directory.appending(path: "received"), encoding: .utf8)
            .split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        #expect(lines.map { $0["request"]?["subtype"]?.string ?? $0["type"]?.string } == [
            "set_model", "apply_flag_settings", "set_permission_mode", "user",
        ])
        #expect(lines[0]["request"]?["model"] == "haiku")
        #expect(lines[1]["request"]?["settings"] == ["effortLevel": "low"])
        #expect(lines[2]["request"]?["mode"] == "bypassPermissions")
    }

    /// A refused change is reported once, with what the CLI still runs with, and not sent again.
    @Test func aRefusedSettingIsReportedAndDropped() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "claude")
        try Data("""
        #!/bin/sh
        cd "$(dirname "$0")"
        read -r line; printf '%s\\n' "$line" >> received
        printf '{"type":"control_response","response":{"subtype":"error","error":"no","request_id":"constellation-set_permission_mode-1"}}\\n'
        while read -r line; do printf '%s\\n' "$line" >> received; done
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: directory, model: "sonnet",
            permissionMode: .askForRisky, prompt: nil, mcpServer: Self.mcpServer
        )
        let session = try ClaudeCodeSession(executable: script, launch: launch, nativeID: "n", environment: [:])
        try await session.begin(message: nil)
        await session.adjust(TurnSettings(model: "sonnet", permissionMode: .fullAuto))
        try await session.send(UserMessage(text: "one"))
        let refusal = try #require(await session.takeRefusal())
        #expect(refusal.applied.permissionMode == .askForRisky)
        #expect(refusal.message.contains("permission mode"))
        #expect(await session.takeRefusal() == nil)
        try await session.send(UserMessage(text: "two"))
        await session.stop()

        let kinds = try String(contentsOf: directory.appending(path: "received"), encoding: .utf8)
            .split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
            .map { $0["request"]?["subtype"]?.string ?? $0["type"]?.string }
        #expect(kinds == ["set_permission_mode", "user", "user"])
    }

    @Test(arguments: [
        ("exec sleep 30", 128 + SIGTERM),
        ("trap '' TERM; while :; do sleep 0.05; done", 128 + SIGKILL),
    ])
    func stopEscalatesWhenTheCLIIgnoresEOF(body: String, expectedCode: Int32) async throws {
        let launch = SessionLaunch(
            sessionID: UUID(), workingDirectory: FileManager.default.temporaryDirectory, model: "m",
            permissionMode: .default, prompt: nil, mcpServer: Self.mcpServer
        )
        let script = FileManager.default.temporaryDirectory.appending(path: "stubborn-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        defer { try? FileManager.default.removeItem(at: script) }

        let grace = Duration.milliseconds(300)
        let session = try ClaudeCodeSession(
            executable: script, launch: launch, nativeID: "n", environment: [:], stopGracePeriod: grace
        )
        try await session.begin(message: nil)
        let elapsed = await ContinuousClock().measure { await session.stop() }
        #expect(elapsed >= grace)

        var events: [SessionEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events == [.started(nativeID: "n"), .exited(code: expectedCode)])
    }
}
