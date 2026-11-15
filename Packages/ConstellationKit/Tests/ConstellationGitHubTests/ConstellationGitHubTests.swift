import ConstellationCore
import Foundation
import Testing
@testable import ConstellationGitHub

@Suite struct RemoteParsingTests {
    @Test(arguments: [
        "git@github.com:ashley-hunter/constellation.git",
        "git@github.com:ashley-hunter/constellation",
        "github.com:ashley-hunter/constellation.git",
        "https://github.com/ashley-hunter/constellation.git",
        "https://github.com/ashley-hunter/constellation",
        "https://token@github.com/ashley-hunter/constellation.git",
        "https://www.github.com/ashley-hunter/constellation",
        "ssh://git@github.com/ashley-hunter/constellation.git",
        "ssh://git@ssh.github.com:443/ashley-hunter/constellation.git",
        "git://github.com/ashley-hunter/constellation.git",
        "  https://github.com/ashley-hunter/constellation.git\n",
    ])
    func parsesGitHubRemotes(remote: String) {
        #expect(GitHubRepository(remoteURL: remote) == GitHubRepository(owner: "ashley-hunter", name: "constellation"))
    }

    @Test(arguments: [
        "git@gitlab.com:ashley-hunter/constellation.git",
        "https://github.example.com/ashley-hunter/constellation.git",
        "https://notgithub.com/a/b",
        "https://github.com/ashley-hunter",
        "https://github.com/ashley-hunter/constellation/pulls",
        "/Users/someone/repos/constellation",
        "",
    ])
    func rejectsOtherRemotes(remote: String) {
        #expect(GitHubRepository(remoteURL: remote) == nil)
    }

    @Test func prefersOriginInRemoteList() {
        let output = """
            fork\tgit@github.com:someone/constellation.git (fetch)
            fork\tgit@github.com:someone/constellation.git (push)
            origin\thttps://github.com/ashley-hunter/constellation.git (fetch)
            origin\thttps://github.com/ashley-hunter/constellation.git (push)
            """
        #expect(GitHubRepository.fromRemoteList(output) == GitHubRepository(owner: "ashley-hunter", name: "constellation"))
    }

    @Test func fallsBackToFirstGitHubRemote() {
        let output = """
            origin\tgit@gitlab.com:ashley/constellation.git (fetch)
            mirror\tgit@github.com:ashley-hunter/constellation.git (fetch)
            """
        #expect(GitHubRepository.fromRemoteList(output) == GitHubRepository(owner: "ashley-hunter", name: "constellation"))
        #expect(GitHubRepository.fromRemoteList("origin\tgit@gitlab.com:a/b.git (fetch)") == nil)
        #expect(GitHubRepository.fromRemoteList("") == nil)
    }
}

@Suite struct QueryTests {
    let cli = GitHubRepository(owner: "cli", name: "cli")

    @Test func aliasesEachBranchAndPassesNamesAsVariables() throws {
        let query = PullRequestQuery(repository: cli, branches: ["feat/a", #"weird"branch"#])
        #expect(query.text.contains("query($owner: String!, $name: String!, $b0: String!, $b1: String!)"))
        #expect(query.text.contains("b0: pullRequests(headRefName: $b0, states: [OPEN, MERGED, CLOSED]"))
        #expect(query.text.contains("b1: pullRequests(headRefName: $b1,"))
        #expect(!query.text.contains("feat/a"))

        let body = try JSONSerialization.jsonObject(with: query.body) as? [String: Any]
        let variables = body?["variables"] as? [String: String]
        #expect(variables == ["owner": "cli", "name": "cli", "b0": "feat/a", "b1": #"weird"branch"#])
    }

    @Test func decodesRecordedCLIResponse() throws {
        let branches = [
            "williammartin-multiaccount-draft-08-evaluation",
            "bagtoad/gh-help-environment-fix",
            "chkp-trunk",
            "no-such-branch-constellation-xyz",
        ]
        let result = try PullRequestQuery(repository: cli, branches: branches).decode(Data(Recorded.cliCLI.utf8))

        #expect(result[branches[0]] == PullRequestInfo(
            number: 14927,
            url: URL(string: "https://github.com/cli/cli/pull/14927")!,
            state: .open,
            isDraft: true,
            reviewDecision: .reviewRequired,
            checks: CheckSummary(state: .failure, passed: 24, total: 25)
        ))
        #expect(result[branches[1]] == PullRequestInfo(
            number: 14918,
            url: URL(string: "https://github.com/cli/cli/pull/14918")!,
            state: .merged,
            reviewDecision: .approved,
            mergedAt: Date(timeIntervalSince1970: 1_793_727_614),
            checks: CheckSummary(state: .success, passed: 18, total: 18)
        ))
        // b2 is a fork PR that happens to share the branch name; b3 has no PR.
        #expect(result.count == 2)
    }

    @Test func dropsForkPullRequests() throws {
        let rails = GitHubRepository(owner: "rails", name: "rails")
        let result = try PullRequestQuery(repository: rails, branches: ["a", "b", "c", "d"]).decode(Data(Recorded.railsRails.utf8))
        #expect(result.isEmpty)
    }

    @Test func countsCheckRunsAndCommitStatusesTogether() throws {
        let response = try JSONDecoder().decode(PullRequestQuery.Response.self, from: Data(Recorded.railsRails.utf8))
        func summary(_ alias: String) -> CheckSummary? {
            response.data?.repository?[alias]??.nodes.first?.commits.nodes.last?.commit.statusCheckRollup?.summary
        }
        // One check run in progress, two statuses pending, one check run passed.
        #expect(summary("b0") == CheckSummary(state: .pending, passed: 1, total: 4))
        // Two successful check runs and two successful statuses.
        #expect(summary("b1") == CheckSummary(state: .success, passed: 4, total: 4))
    }

    @Test func prefersOpenPullRequestOverOlderMergedOne() throws {
        let json = """
            {"data":{"repository":{"b0":{"nodes":[
              {"number":2,"url":"https://github.com/o/r/pull/2","state":"MERGED","isDraft":false,"reviewDecision":null,"mergedAt":"2026-11-01T00:00:00Z","isCrossRepository":false,"commits":{"nodes":[]}},
              {"number":5,"url":"https://github.com/o/r/pull/5","state":"OPEN","isDraft":false,"reviewDecision":null,"mergedAt":null,"isCrossRepository":false,"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}
            ]}}}}
            """
        let result = try PullRequestQuery(repository: GitHubRepository(owner: "o", name: "r"), branches: ["x"]).decode(Data(json.utf8))
        #expect(result["x"]?.number == 5)
        #expect(result["x"]?.checks == nil)
    }

    // Recorded live: querying a repository that does not exist.
    @Test func reportsMissingRepository() {
        let json = #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],"locations":[{"line":3,"column":3}],"message":"Could not resolve to a Repository with the name 'cli/no-such-repo-xyz-constellation'."}]}"#
        #expect(throws: GitHubError.repositoryNotFound) {
            try PullRequestQuery(repository: cli, branches: ["x"]).decode(Data(json.utf8))
        }
    }

    @Test func reportsRateLimitAndGarbage() {
        let limited = #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(60))) {
            try PullRequestQuery(repository: cli, branches: ["x"]).decode(Data(limited.utf8))
        }
        #expect(throws: GitHubError.invalidResponse) {
            try PullRequestQuery(repository: cli, branches: ["x"]).decode(Data("<html>".utf8))
        }
    }
}

@Suite struct PollIntervalTests {
    let url = URL(string: "https://github.com/o/r/pull/1")!

    @Test func adaptsToPullRequestAndSession() {
        let interval = GitHubStatusService.pollInterval
        let green = CheckSummary(state: .success, passed: 3, total: 3)
        let red = CheckSummary(state: .failure, passed: 2, total: 3)
        let approvedGreen = PullRequestInfo(number: 1, url: url, state: .open, reviewDecision: .approved, checks: green)

        #expect(interval(nil, false) == .seconds(60))
        #expect(interval(approvedGreen, false) == .seconds(15))
        #expect(interval(approvedGreen, true) == .seconds(300))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .open, reviewDecision: .approved), false) == .seconds(15))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .open, reviewDecision: .approved, checks: red), false) == .seconds(30))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .open, checks: green), false) == .seconds(30))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .open, isDraft: true), false) == .seconds(60))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .merged), false) == .seconds(300))
        #expect(interval(PullRequestInfo(number: 1, url: url, state: .closed), false) == .seconds(300))
    }
}
