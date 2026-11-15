import ConstellationCore
import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct ProviderCheckTests {
    @Test func readsVersionsFromEitherCLI() {
        #expect(ProviderCheck.version(from: "2.1.314 (Claude Code)\n") == "2.1.314")
        #expect(ProviderCheck.version(from: "codex-cli 0.166.0") == "0.166.0")
        #expect(ProviderCheck.version(from: "v1.2.3") == "1.2.3")
        #expect(ProviderCheck.version(from: "command not found") == nil)
    }

    @Test func readsClaudeAuthStatus() {
        let signedIn = Data(#"{"loggedIn": true, "authMethod": "claude.ai", "email": "a@example.com"}"#.utf8)
        #expect(ProviderCheck.claudeAuth(from: signedIn) == .init(isSignedIn: true, account: "a@example.com"))
        let console = Data(#"{"loggedIn": true, "authMethod": "console"}"#.utf8)
        #expect(ProviderCheck.claudeAuth(from: console) == .init(isSignedIn: true, account: "console"))
        let signedOut = Data(#"{"loggedIn": false}"#.utf8)
        #expect(ProviderCheck.claudeAuth(from: signedOut) == .init(isSignedIn: false))
        #expect(ProviderCheck.claudeAuth(from: Data("Not logged in".utf8)) == nil)
    }

    @Test func readsCodexAccount() throws {
        func result(_ json: String) throws -> CodexJSON { try JSONDecoder().decode(CodexJSON.self, from: Data(json.utf8)) }
        let chatGPT = try result(#"{"account": {"type": "chatgpt", "email": "a@example.com", "planType": "plus"}, "requiresOpenaiAuth": true}"#)
        #expect(ProviderCheck.codexAccount(from: chatGPT) == .init(isSignedIn: true, account: "a@example.com"))
        let apiKey = try result(#"{"account": {"type": "apiKey"}}"#)
        #expect(ProviderCheck.codexAccount(from: apiKey) == .init(isSignedIn: true, account: "API key"))
        #expect(ProviderCheck.codexAccount(from: try result(#"{"account": null, "requiresOpenaiAuth": true}"#)) == .init(isSignedIn: false))
        #expect(ProviderCheck.codexAccount(from: try result(#"{}"#)) == nil)
    }

    @Test func stateFollowsBinaryAndSignIn() {
        let binary = URL(filePath: "/usr/local/bin/claude")
        #expect(ProviderStatus(provider: .claudeCode).state == .missing)
        #expect(ProviderStatus(provider: .claudeCode, binary: binary, isSignedIn: false).state == .signedOut)
        #expect(ProviderStatus(provider: .claudeCode, binary: binary).state == .unknown)
        #expect(ProviderStatus(provider: .claudeCode, binary: binary).isUsable)
        #expect(ProviderStatus(provider: .claudeCode, binary: binary, isSignedIn: true).state == .ready)
        #expect(!ProviderStatus(provider: .codex, binary: binary, isSignedIn: false).isUsable)
    }
}
