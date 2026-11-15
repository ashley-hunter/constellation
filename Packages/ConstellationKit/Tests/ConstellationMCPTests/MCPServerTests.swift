import ConstellationCore
import Foundation
import Testing
@testable import ConstellationMCP

private actor FakeBackend: MCPToolBackend {
    var secret: String?
    var outcomes: [Outcome] = []
    var secretRequests: [String] = []

    init(secret: String?) { self.secret = secret }

    func requestSecret(name: String, reason: String) async throws -> String? {
        secretRequests.append(name)
        return secret
    }

    func reportOutcome(_ outcome: Outcome) async throws {
        outcomes.append(outcome)
    }
}

private func call(_ server: MCPServer, _ request: String) async throws -> JSONValue {
    let data = try #require(await server.response(to: Data(request.utf8)))
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func initializeEchoesSupportedVersionAndCarriesInstructions() async throws {
    let server = MCPServer(backend: FakeBackend(secret: nil)) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    #expect(response["id"] == 0)
    #expect(response["result"]?["protocolVersion"] == "2025-06-18")
    #expect(response["result"]?["serverInfo"]?["name"] == "constellation")
    let instructions = try #require(response["result"]?["instructions"]?.stringValue)
    #expect(instructions.contains("report_outcome"))
    #expect(instructions.contains("request_secret"))
}

@Test func initializeOffersNewestVersionForUnknownRequests() async throws {
    let server = MCPServer(backend: FakeBackend(secret: nil)) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
    #expect(response["id"] == "a")
    #expect(response["result"]?["protocolVersion"] == .string(MCPServer.supportedProtocolVersions[0]))
}

@Test func toolsListNamesBothTools() async throws {
    let server = MCPServer(backend: FakeBackend(secret: nil)) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    guard case let .array(tools) = response["result"]?["tools"] else { Issue.record("no tools"); return }
    #expect(tools.compactMap { $0["name"]?.stringValue } == ["request_secret", "report_outcome"])
}

@Test func reportOutcomeReachesBackend() async throws {
    let backend = FakeBackend(secret: nil)
    let server = MCPServer(backend: backend) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"report_outcome","arguments":{"status":"failed","summary":"Tests still red"}}}"#)
    #expect(response["result"]?["isError"] == false)
    #expect(await backend.outcomes == [Outcome(status: .failed, summary: "Tests still red")])
}

@Test func reportOutcomeRejectsUnknownStatus() async throws {
    let backend = FakeBackend(secret: nil)
    let server = MCPServer(backend: backend) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"report_outcome","arguments":{"status":"meh","summary":"x"}}}"#)
    #expect(response["result"]?["isError"] == true)
    #expect(await backend.outcomes.isEmpty)
}

@Test func requestSecretReturnsValueOrDenial() async throws {
    let request = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"request_secret","arguments":{"name":"STRIPE_KEY","reason":"webhooks"}}}"#

    let granted = try await call(MCPServer(backend: FakeBackend(secret: "sk_test_1")) { _ in }, request)
    #expect(granted["result"]?["isError"] == false)
    let text = try #require(granted["result"]?["content"].flatMap { if case let .array(items) = $0 { items.first?["text"] } else { nil } }?.stringValue)
    #expect(text.contains("env var STRIPE_KEY"))
    #expect(text.hasSuffix(MCPServer.secretValueMarker + "sk_test_1"))

    let denied = try await call(MCPServer(backend: FakeBackend(secret: nil)) { _ in }, request)
    #expect(denied["result"]?["isError"] == true)
}

@Test func requestSecretRejectsNamesThatAreNotEnvironmentVariables() async throws {
    let backend = FakeBackend(secret: "x")
    let server = MCPServer(backend: backend) { _ in }
    let response = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"request_secret","arguments":{"name":"rm -rf","reason":"?"}}}"#)
    #expect(response["result"]?["isError"] == true)
    #expect(await backend.secretRequests.isEmpty)
}

@Test func unknownMethodsAndBadJSONAreErrors() async throws {
    let server = MCPServer(backend: FakeBackend(secret: nil)) { _ in }
    #expect(try await call(server, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)["error"]?["code"] == -32601)
    #expect(try await call(server, "not json")["error"]?["code"] == -32700)
    #expect(await server.response(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    #expect(await server.response(to: Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8)) == nil)
}

@Test func environmentVariableNames() {
    #expect("STRIPE_WEBHOOK_SECRET".isEnvironmentVariableName)
    #expect("_x1".isEnvironmentVariableName)
    #expect(!"1ABC".isEnvironmentVariableName)
    #expect(!"A-B".isEnvironmentVariableName)
    #expect(!"".isEnvironmentVariableName)
    #expect(!"ÉCLAIR".isEnvironmentVariableName)
}
