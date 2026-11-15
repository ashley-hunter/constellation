import ConstellationCore
import Foundation
import Testing
@testable import ConstellationMCP

@Test func serverConfigCarriesSessionAndSocket() {
    let bridge = MCPBridge(socketURL: URL(filePath: "/tmp/c/mcp.sock"))
    let id = UUID()
    let config = bridge.serverConfig(for: id, helper: URL(filePath: "/Helpers/constellation-mcp"))
    #expect(config.environment[MCPBridge.sessionIDEnvironmentKey] == id.uuidString)
    #expect(config.environment[MCPBridge.socketEnvironmentKey] == "/tmp/c/mcp.sock")
}

@Test func claudeConfigIsAnMCPServersObject() throws {
    let config = MCPServerConfig(command: URL(filePath: "/App/Helpers/constellation-mcp"), environment: ["A": "1"])
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(config.claudeMCPConfigJSON().utf8))
    let server = json["mcpServers"]?["constellation"]
    #expect(server?["type"] == "stdio")
    #expect(server?["command"] == "/App/Helpers/constellation-mcp")
    #expect(server?["env"]?["A"] == "1")
    #expect(MCPServerConfig.claudeAllowedTools == ["mcp__constellation__request_secret", "mcp__constellation__report_outcome"])
}

@Test func codexConfigUsesSnakeCaseKeys() throws {
    let config = MCPServerConfig(command: URL(filePath: "/h/constellation-mcp"), environment: ["A": "1"])
    #expect(config.codexConfigKey == "mcp_servers.constellation")
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(config.codexServer))
    #expect(json["command"] == "/h/constellation-mcp")
    #expect(json["tool_timeout_sec"] == .int(604_800))
    #expect(json["default_tools_approval_mode"] == "approve")
}

@Test func socketMessagesRoundTrip() throws {
    let messages: [MCPSocketMessage] = [
        .requestSecret(id: UUID(), sessionID: UUID(), name: "KEY", reason: "why"),
        .cancelSecretRequest(id: UUID()),
        .secretResponse(id: UUID(), value: nil),
        .secretResponse(id: UUID(), value: "line\u{2028}break"),
        .reportOutcome(sessionID: UUID(), Outcome(status: .succeeded, summary: "done")),
    ]
    for message in messages {
        let data = try JSONEncoder().encode(message)
        #expect(!data.contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(MCPSocketMessage.self, from: data) == message)
    }
}

@Test(.timeLimit(.minutes(1))) func bridgeRoutesASecretAnswerBackToItsConnection() async throws {
    let bridge = MCPBridge(socketURL: temporarySocketURL())
    try await bridge.start()
    defer { Task { await bridge.stop() } }
    var requests = bridge.requests.makeAsyncIterator()

    let fd = try UnixSocket.connect(to: bridge.socketURL.path(percentEncoded: false))
    defer { close(fd) }
    var lines = LineReader.lines(from: fd).makeAsyncIterator()
    let id = UUID(), session = UUID()
    var data = try JSONEncoder().encode(MCPSocketMessage.requestSecret(id: id, sessionID: session, name: "K", reason: "r"))
    data.append(UInt8(ascii: "\n"))
    try UnixSocket.write(data, to: fd)

    #expect(await requests.next() == .requestSecret(id: id, sessionID: session, name: "K", reason: "r"))
    await bridge.respond(toSecretRequest: id, value: "v")
    let line = try #require(await lines.next())
    #expect(try JSONDecoder().decode(MCPSocketMessage.self, from: line) == .secretResponse(id: id, value: "v"))
}
