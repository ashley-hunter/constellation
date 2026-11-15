import ConstellationCore
import Testing
@testable import ConstellationProviders

@Test func permissionModesMapToProviderSettings() {
    #expect(ClaudeCodeAdapter.permissionModeArgument(for: .askForRisky) == "acceptEdits")
    #expect(CodexAdapter.policy(for: .fullAuto) == ("never", "danger-full-access"))
}
