import ConstellationCore
import Foundation

/// One GraphQL request covering several branches of a repository, each as an aliased
/// `pullRequests(headRefName:)` field. Verified live on 2026-11-04: costs 1 point per ~10 branches.
struct PullRequestQuery: Sendable {
    let repository: GitHubRepository
    let branches: [String]

    /// GraphQL aliases must be names, so branch `i` is fetched as `b<i>` and passed as variable `$b<i>`.
    var body: Data {
        struct Body: Encodable {
            var query: String
            var variables: [String: String]
        }
        var variables = ["owner": repository.owner, "name": repository.name]
        for (index, branch) in branches.enumerated() { variables["b\(index)"] = branch }
        // Encoding a struct of strings cannot fail.
        return try! JSONEncoder().encode(Body(query: text, variables: variables))
    }

    var text: String {
        let parameters = (["$owner: String!", "$name: String!"]
            + branches.indices.map { "$b\($0): String!" }).joined(separator: ", ")
        let fields = branches.indices.map {
            "    b\($0): pullRequests(headRefName: $b\($0), states: [OPEN, MERGED, CLOSED], first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) { ...pr }"
        }.joined(separator: "\n")
        return """
            query(\(parameters)) {
              repository(owner: $owner, name: $name) {
            \(fields)
              }
            }
            \(Self.fragment)
            """
    }

    static let fragment = """
        fragment pr on PullRequestConnection {
          nodes {
            number url state isDraft reviewDecision mergedAt isCrossRepository
            commits(last: 1) { nodes { commit { statusCheckRollup {
              state
              contexts(first: 1) {
                totalCount
                checkRunCountsByState { state count }
                statusContextCountsByState { state count }
              }
            } } } }
          }
        }
        """

    /// Keys are branch names; branches without a PR from this repository are absent.
    func decode(_ data: Data) throws(GitHubError) -> [String: PullRequestInfo] {
        let response: Response
        do {
            response = try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw .invalidResponse
        }
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            throw .rateLimited(retryAfter: .seconds(60))
        }
        guard let connections = response.data?.repository else {
            if errors.contains(where: { $0.type == "NOT_FOUND" }) { throw .repositoryNotFound }
            throw .graphQL(errors.first?.message ?? "No repository in response")
        }

        var result: [String: PullRequestInfo] = [:]
        for (index, branch) in branches.enumerated() {
            guard let nodes = connections["b\(index)"]??.nodes, let node = Self.pick(nodes) else { continue }
            result[branch] = node.info
        }
        return result
    }

    /// Prefers an open PR, then the most recently updated one. Fork PRs that reuse the branch name are ignored.
    private static func pick(_ nodes: [Node]) -> Node? {
        let own = nodes.filter { !$0.isCrossRepository }
        return own.first { $0.state == "OPEN" } ?? own.first
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Response shape

extension PullRequestQuery {
    struct Response: Decodable {
        var data: DataField?
        var errors: [ErrorField]?
    }

    struct DataField: Decodable {
        var repository: [String: Connection?]?
    }

    struct ErrorField: Decodable {
        var type: String?
        var message: String
    }

    struct Connection: Decodable {
        var nodes: [Node]
    }

    struct Node: Decodable {
        var number: Int
        var url: URL
        var state: String
        var isDraft: Bool
        var reviewDecision: String?
        var mergedAt: Date?
        var isCrossRepository: Bool
        var commits: Commits

        struct Commits: Decodable {
            var nodes: [CommitNode]
        }

        struct CommitNode: Decodable {
            var commit: Commit
        }

        struct Commit: Decodable {
            var statusCheckRollup: Rollup?
        }

        var info: PullRequestInfo {
            PullRequestInfo(
                number: number,
                url: url,
                state: PullRequestInfo.State(rawValue: state.lowercased()) ?? .open,
                isDraft: isDraft,
                reviewDecision: reviewDecision.flatMap(Self.reviewDecision),
                mergedAt: mergedAt,
                checks: commits.nodes.last?.commit.statusCheckRollup?.summary
            )
        }

        private static func reviewDecision(_ raw: String) -> PullRequestInfo.ReviewDecision? {
            switch raw {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .reviewRequired
            default: nil
            }
        }
    }

    struct Rollup: Decodable {
        var state: String
        var contexts: Contexts

        struct Contexts: Decodable {
            var totalCount: Int
            var checkRunCountsByState: [StateCount]?
            var statusContextCountsByState: [StateCount]?
        }

        struct StateCount: Decodable {
            var state: String
            var count: Int
        }

        /// Skipped and neutral check runs count as passed, matching how GitHub treats them for merging.
        static let passingCheckRunStates: Set<String> = ["SUCCESS", "NEUTRAL", "SKIPPED"]

        var summary: CheckSummary? {
            guard let state = CheckSummary.State(rawValue: state.lowercased()) else { return nil }
            let checkRunsPassed = (contexts.checkRunCountsByState ?? [])
                .filter { Self.passingCheckRunStates.contains($0.state) }
                .reduce(0) { $0 + $1.count }
            let statusesPassed = (contexts.statusContextCountsByState ?? [])
                .filter { $0.state == "SUCCESS" }
                .reduce(0) { $0 + $1.count }
            return CheckSummary(state: state, passed: checkRunsPassed + statusesPassed, total: contexts.totalCount)
        }
    }
}
