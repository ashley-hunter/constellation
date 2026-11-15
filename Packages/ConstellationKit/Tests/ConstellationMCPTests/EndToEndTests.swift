import ConstellationCore
import Foundation
import Testing
@testable import ConstellationMCP

/// Spawns the built `constellation-mcp` and speaks MCP over its stdio, with a real `MCPBridge` on the other side.
@Suite(.timeLimit(.minutes(1)))
struct EndToEndTests {
    let sessionID = UUID()

    @Test func toolCallsReachTheBridge() async throws {
        let bridge = MCPBridge(socketURL: temporarySocketURL())
        try await bridge.start()
        defer { Task { await bridge.stop() } }
        var requests = bridge.requests.makeAsyncIterator()
        let helper = try Helper(config: bridge.serverConfig(for: sessionID, helper: Helper.executableURL))

        let initialize = try await helper.request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(initialize["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialize["result"]?["instructions"]?.stringValue?.contains("report_outcome") == true)
        helper.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        let list = try await helper.request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case let .array(tools) = list["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.count == 2)

        let outcome = try await helper.request(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"report_outcome","arguments":{"status":"succeeded","summary":"Added the webhook handler"}}}"#)
        #expect(outcome["result"]?["isError"] == false)
        #expect(await requests.next() == .reportOutcome(sessionID: sessionID, Outcome(status: .succeeded, summary: "Added the webhook handler")))

        helper.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"request_secret","arguments":{"name":"STRIPE_WEBHOOK_SECRET","reason":"verify signatures"}}}"#)
        guard case let .requestSecret(requestID, session, name, reason) = await requests.next() else {
            Issue.record("expected a secret request"); return
        }
        #expect(session == sessionID)
        #expect(name == "STRIPE_WEBHOOK_SECRET")
        #expect(reason == "verify signatures")
        await bridge.respond(toSecretRequest: requestID, value: "whsec_123")
        let secret = try await helper.next()
        #expect(secret["id"] == 4)
        #expect(secret["result"]?["isError"] == false)
        #expect(String(describing: secret).contains("whsec_123"))

        helper.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"request_secret","arguments":{"name":"TOKEN","reason":"deploy"}}}"#)
        guard case let .requestSecret(cancelledID, _, _, _) = await requests.next() else {
            Issue.record("expected a secret request"); return
        }
        helper.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}"#)
        #expect(await requests.next() == .secretRequestWithdrawn(id: cancelledID))
        #expect(try await helper.request(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)["id"] == 6)

        #expect(try await helper.finish() == 0)
    }

    @Test func pendingSecretIsWithdrawnWhenTheHelperExits() async throws {
        let bridge = MCPBridge(socketURL: temporarySocketURL())
        try await bridge.start()
        defer { Task { await bridge.stop() } }
        var requests = bridge.requests.makeAsyncIterator()
        let helper = try Helper(config: bridge.serverConfig(for: sessionID, helper: Helper.executableURL))

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"request_secret","arguments":{"name":"TOKEN","reason":"deploy"}}}"#)
        guard case let .requestSecret(requestID, _, _, _) = await requests.next() else {
            Issue.record("expected a secret request"); return
        }
        helper.process.terminate()
        #expect(await requests.next() == .secretRequestWithdrawn(id: requestID))
    }

    @Test func toolsReportAnErrorWhenTheAppIsNotRunning() async throws {
        let bridge = MCPBridge(socketURL: temporarySocketURL())
        let helper = try Helper(config: bridge.serverConfig(for: sessionID, helper: Helper.executableURL))
        let response = try await helper.request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report_outcome","arguments":{"status":"succeeded","summary":"x"}}}"#)
        #expect(response["result"]?["isError"] == true)
        #expect(try await helper.finish() == 0)
    }
}

func temporarySocketURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "cm-\(UUID().uuidString.prefix(8))")
        .appending(path: "mcp.sock")
}

private final class Helper {
    static var executableURL: URL {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let candidates = [
            bundle?.bundleURL.deletingLastPathComponent().appending(path: "constellation-mcp"),
            URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug/constellation-mcp"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? URL(filePath: "/missing/constellation-mcp: run swift build first")
    }

    let process = Process()
    private let input = Pipe()
    private var lines: AsyncStream<Data>.Iterator

    init(config: MCPServerConfig) throws {
        let output = Pipe()
        process.executableURL = config.command
        process.arguments = config.arguments
        process.environment = config.environment
        process.standardInput = input
        process.standardOutput = output
        lines = LineReader.lines(from: output.fileHandleForReading.fileDescriptor).makeAsyncIterator()
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func send(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func next() async throws -> JSONValue {
        let line = try #require(await lines.next())
        return try JSONDecoder().decode(JSONValue.self, from: line)
    }

    func request(_ line: String) async throws -> JSONValue {
        send(line)
        return try await next()
    }

    /// Closes stdin and waits for the helper to exit.
    func finish() async throws -> Int32 {
        try input.fileHandleForWriting.close()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        return process.terminationStatus
    }
}
