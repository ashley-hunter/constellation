import ConstellationCore
import Foundation
import Synchronization
import Testing
@testable import ConstellationGitHub

private let cli = GitHubRepository(owner: "cli", name: "cli")

private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: status, httpVersion: nil, headerFields: headers)!
}

@Suite struct ServiceTests {
    @Test func refreshesTokenOnceAfter401() async throws {
        let tokens = Mutex(["stale", "fresh"])
        let authHeaders = Mutex<[String]>([])
        let service = GitHubStatusService(
            tokenSource: { tokens.withLock { $0.removeFirst() } },
            transport: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                authHeaders.withLock { $0.append(auth) }
                return auth == "bearer fresh" ? (Data(Recorded.cliCLI.utf8), response(200)) : (Data(), response(401))
            }
        )

        let branch = "williammartin-multiaccount-draft-08-evaluation"
        let result = try await service.pullRequests(repository: cli, branches: [branch])

        #expect(result[branch]?.number == 14927)
        #expect(authHeaders.withLock { $0 } == ["bearer stale", "bearer fresh"])
        #expect(tokens.withLock { $0.isEmpty })
    }

    @Test func givesUpWhenTheFreshTokenIsAlsoRejected() async {
        let service = GitHubStatusService(tokenSource: { "t" }, transport: { _ in (Data(), response(401)) })
        await #expect(throws: GitHubError.unauthorized) {
            try await service.pullRequests(repository: cli, branches: ["x"])
        }
    }

    @Test func surfacesMissingToken() async {
        let service = GitHubStatusService(tokenSource: { throw GitHubError.noToken }, transport: { _ in Issue.record("no request expected"); return (Data(), response(500)) })
        await #expect(throws: GitHubError.noToken) {
            try await service.pullRequests(repository: cli, branches: ["x"])
        }
    }

    @Test func readsRateLimitHeaders() async {
        let secondary = GitHubStatusService(tokenSource: { "t" }, transport: { _ in (Data(), response(403, headers: ["Retry-After": "42"])) })
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(42))) {
            try await secondary.pullRequests(repository: cli, branches: ["x"])
        }

        let forbidden = GitHubStatusService(tokenSource: { "t" }, transport: { _ in (Data(), response(403)) })
        await #expect(throws: GitHubError.requestFailed(status: 403)) {
            try await forbidden.pullRequests(repository: cli, branches: ["x"])
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let primary = response(200, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1090"])
        #expect(GitHubStatusService.retryDelay(primary, now: now) == .seconds(90))
        #expect(GitHubStatusService.retryDelay(response(200, headers: ["X-RateLimit-Remaining": "12"]), now: now) == nil)
    }

    @Test func batchesBranchesIntoChunkedRequests() async throws {
        let requestedBranches = Mutex<[Int]>([])
        let service = GitHubStatusService(tokenSource: { "t" }, transport: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = body["variables"] as! [String: String]
            requestedBranches.withLock { $0.append(variables.count - 2) }
            return (Data(#"{"data":{"repository":{}}}"#.utf8), response(200))
        })

        let branches = (0..<120).map { "branch-\($0)" } + ["branch-0"]
        let result = try await service.pullRequests(repository: cli, branches: branches)

        #expect(result.isEmpty)
        #expect(requestedBranches.withLock { $0 } == [50, 50, 20])
        #expect(try await service.pullRequests(repository: cli, branches: []).isEmpty)
        #expect(requestedBranches.withLock { $0.count } == 3)
    }
}
