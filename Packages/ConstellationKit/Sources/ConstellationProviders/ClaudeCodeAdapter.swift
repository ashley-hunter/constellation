import ConstellationCore
import Foundation

/// One long-lived `claude -p --input-format stream-json` process per session.
public actor ClaudeCodeAdapter: ProviderAdapter, ModelCatalog {
    public nonisolated let provider = Provider.claudeCode

    private let locator: BinaryLocator

    public init(locator: BinaryLocator = .shared) {
        self.locator = locator
    }

    public func start(_ launch: SessionLaunch) async throws -> any ProviderSessionHandle {
        let executable = try await locator.locate("claude")
        let environment = Self.environment(for: launch, searchPath: await locator.searchPath())
        // A new session, a fork or a rewind to the very start gets a fresh id up front; a resumed one keeps its id.
        let nativeID = Self.keepsNativeID(launch) ? launch.resumeID! : UUID().uuidString.lowercased()
        let session = try ClaudeCodeSession(executable: executable, launch: launch, nativeID: nativeID, environment: environment)
        try await session.begin(message: launch.message)
        return session
    }

    static func keepsNativeID(_ launch: SessionLaunch) -> Bool {
        switch (launch.resumeID, launch.cut) {
        case (nil, _), (_, .fork?), (_, .rewind(before: nil)?): false
        default: true
        }
    }

    /// The Claude Code `--permission-mode` value for a Constellation permission mode.
    public static func permissionModeArgument(for mode: PermissionMode) -> String {
        switch mode {
        case .askForEverything: "default"
        case .askForRisky: "acceptEdits"
        case .fullAuto: "bypassPermissions"
        }
    }

    /// Claude Code takes aliases for the latest of each model. Effort changes mid-session go through
    /// the `effortLevel` setting, which stops at xhigh.
    public nonisolated func models() -> [ModelChoice] {
        let efforts = ["low", "medium", "high", "xhigh"]
        return [
            ModelChoice(id: "opus", title: "Opus", efforts: efforts),
            ModelChoice(id: "sonnet", title: "Sonnet", efforts: efforts),
            ModelChoice(id: "haiku", title: "Haiku", efforts: efforts),
        ]
    }

    static func environment(
        for launch: SessionLaunch,
        searchPath: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = searchPath
        // Without this the CLI never emits `session_state_changed` (verified on 2.1.314).
        environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1"
        environment.merge(launch.environment) { $1 }
        return environment
    }
}
