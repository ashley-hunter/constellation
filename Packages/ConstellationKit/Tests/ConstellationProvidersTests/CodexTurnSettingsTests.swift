import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct CodexTurnSettingsTests {
    private func handle(_ settings: TurnSettings) throws -> CodexSessionHandle {
        let server = CodexAppServer(transport: try CodexReplayTransport(fixture: "codex-completion"))
        return CodexSessionHandle(sessionID: UUID(), threadID: "t", model: "gpt-6.1-sol", settings: settings, workingDirectory: "/tmp", server: server)
    }

    private func encoded(_ params: CodexTurnStartParams) throws -> CodexJSON {
        try CodexJSON(encoding: params)
    }

    @Test func aTurnWithTheLaunchSettingsOnlyNamesTheMode() async throws {
        let handle = try handle(TurnSettings(model: ""))
        let params = try encoded(await handle.turnStartParams([.text("hi")]))
        #expect(params["collaborationMode"] == .object([
            "mode": .string("default"),
            "settings": .object(["model": .string("gpt-6.1-sol"), "developer_instructions": .null]),
        ]))
        for key in ["model", "effort", "serviceTier", "approvalPolicy", "sandboxPolicy"] {
            #expect(params[key] == nil, "\(key) should be left to the thread")
        }
    }

    @Test func changedSettingsGoOutWithTheNextTurn() async throws {
        let handle = try handle(TurnSettings(model: "", permissionMode: .askForRisky))
        await handle.adjust(TurnSettings(model: "gpt-5.6-luna", effort: "low", fastMode: true, permissionMode: .fullAuto))
        let params = try encoded(await handle.turnStartParams([.text("hi")]))
        #expect(params["model"] == .string("gpt-5.6-luna"))
        #expect(params["effort"] == .string("low"))
        #expect(params["serviceTier"] == .string("priority"))
        #expect(params["approvalPolicy"] == .string("never"))
        #expect(params["sandboxPolicy"] == .object(["type": .string("dangerFullAccess")]))
        #expect(params["collaborationMode"]?["mode"] == .string("default"))
        #expect(params["collaborationMode"]?["settings"]?["reasoning_effort"] == .string("low"))
    }
}
