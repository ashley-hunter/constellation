import ConstellationCore
import ConstellationProcess
import Foundation

/// Whether a provider's CLI is installed and signed in, as onboarding shows it.
public struct ProviderStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case missing
        case signedOut
        /// Installed, but the sign-in check failed, so we can't tell.
        case unknown
        case ready
    }

    public var provider: Provider
    public var binary: URL?
    public var version: String?
    /// Nil when the check couldn't tell.
    public var isSignedIn: Bool?
    /// The signed-in account's email or plan, when the CLI reports one.
    public var account: String?

    public init(provider: Provider, binary: URL? = nil, version: String? = nil, isSignedIn: Bool? = nil, account: String? = nil) {
        self.provider = provider
        self.binary = binary
        self.version = version
        self.isSignedIn = isSignedIn
        self.account = account
    }

    public var state: State {
        guard binary != nil else { return .missing }
        switch isSignedIn {
        case true?: return .ready
        case false?: return .signedOut
        case nil: return .unknown
        }
    }

    /// Ready, or installed with a sign-in we couldn't check: either can start a session.
    public var isUsable: Bool { state == .ready || state == .unknown }
}

/// Detects Claude Code and Codex: the binary on the login shell's `PATH`, its version, and its
/// sign-in (`claude auth status`; Codex's `account/read` over a short-lived app-server).
public enum ProviderCheck {
    public static func check(_ provider: Provider, locator: BinaryLocator = .shared) async -> ProviderStatus {
        var status = ProviderStatus(provider: provider)
        guard let binary = try? await locator.locate(provider.binaryName) else { return status }
        status.binary = binary
        let environment = await environment(for: binary, locator: locator)
        if let output = try? await run(binary, ["--version"], environment: environment) {
            status.version = version(from: output.text)
        }
        switch provider {
        case .claudeCode:
            if let output = try? await run(binary, ["auth", "status"], environment: environment),
               let auth = claudeAuth(from: output.data) {
                status.isSignedIn = auth.isSignedIn
                status.account = auth.account
            }
        case .codex:
            if let auth = await codexAccount(binary: binary, environment: environment) {
                status.isSignedIn = auth.isSignedIn
                status.account = auth.account
            }
        }
        return status
    }

    /// The command that installs a provider, for a terminal to run.
    public static func installCommand(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        }
    }

    public static func signInCommand(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: "claude auth login"
        case .codex: "codex login"
        }
    }

    // MARK: Parsing

    /// The first dotted version number: "2.1.314 (Claude Code)" and "codex-cli 0.166.0" both work.
    static func version(from output: String) -> String? {
        output.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            .map { $0.hasPrefix("v") ? $0.dropFirst() : $0 }
            .first { word in word.contains(".") && word.allSatisfy { $0.isNumber || $0 == "." } && word.first?.isNumber == true }
            .map(String.init)
    }

    struct Auth: Hashable {
        var isSignedIn: Bool
        var account: String?
    }

    /// `claude auth status` prints JSON with `loggedIn` and, for a claude.ai sign-in, `email`.
    static func claudeAuth(from data: Data) -> Auth? {
        guard let json = try? JSONDecoder().decode(CodexJSON.self, from: data),
              case .bool(let loggedIn)? = json["loggedIn"] else { return nil }
        return Auth(isSignedIn: loggedIn, account: json["email"]?.stringValue ?? json["authMethod"]?.stringValue)
    }

    /// `account/read` answers `{"account": null}` when signed out, otherwise the account with its
    /// type ("chatgpt" or "apiKey") and, for ChatGPT, the email.
    static func codexAccount(from result: CodexJSON) -> Auth? {
        guard let account = result["account"] else { return nil }
        if account == .null { return Auth(isSignedIn: false) }
        let label = account["email"]?.stringValue ?? (account["type"]?.stringValue == "apiKey" ? "API key" : nil)
        return Auth(isSignedIn: true, account: label)
    }

    // MARK: Running

    private struct Output {
        var data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    private static func environment(for binary: URL, locator: BinaryLocator) async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = binary.deletingLastPathComponent().path(percentEncoded: false) + ":" + (await locator.searchPath())
        return environment
    }

    /// Runs a short command and returns its stdout, whatever its exit status (`claude auth status`
    /// exits non-zero when signed out). Gives up after ten seconds.
    private static func run(_ binary: URL, _ arguments: [String], environment: [String: String]) async throws -> Output {
        let process = try ChildProcess(
            executable: binary, arguments: arguments, environment: environment,
            standardError: .null, disclaimsResponsibility: true
        )
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            process.signalGroup(SIGTERM)
        }
        defer { timeout.cancel() }
        let handle = process.standardOutput
        let data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle?.readDataToEndOfFile() ?? Data())
            }
        }
        _ = await process.waitForExit()
        return Output(data: data)
    }

    private static func codexAccount(binary: URL, environment: [String: String]) async -> Auth? {
        guard let transport = try? CodexProcess(executable: binary, arguments: ["app-server"], environment: environment) else { return nil }
        let server = CodexAppServer(transport: transport)
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            await server.close()
        }
        defer {
            timeout.cancel()
            Task { await server.close() }
        }
        do {
            try await server.start()
            let result: CodexJSON = try await server.request(CodexMethod.accountRead, CodexJSON.object([:]))
            return codexAccount(from: result)
        } catch {
            return nil
        }
    }
}

extension Provider {
    var binaryName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }
}
