import Foundation
import Testing
@testable import ConstellationGitHub

/// Read-only queries against public GitHub repos with the local `gh` token.
/// Run with `CONSTELLATION_LIVE_GITHUB=1 swift test --filter LiveGitHubTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONSTELLATION_LIVE_GITHUB"] == "1"))
struct LiveGitHubTests {
    @Test func fetchesMergedPullRequestFromCLI() async throws {
        let service = GitHubStatusService()
        let result = try await service.pullRequests(
            repository: GitHubRepository(owner: "cli", name: "cli"),
            branches: ["bagtoad/gh-help-environment-fix", "no-such-branch-constellation-xyz"]
        )
        #expect(result["bagtoad/gh-help-environment-fix"]?.number == 14918)
        #expect(result["bagtoad/gh-help-environment-fix"]?.state == .merged)
        #expect(result["no-such-branch-constellation-xyz"] == nil)
    }

    @Test func resolvesThisCheckout() async {
        let here = URL(filePath: #filePath).deletingLastPathComponent()
        #expect(await GitHubRepository.resolve(repositoryAt: here) != nil)
        #expect(await GitHubRepository.resolve(repositoryAt: URL(filePath: "/")) == nil)
    }
}
