import ConstellationCore
import Foundation

/// PR and CI status per branch, from one GraphQL query per repo using the `gh auth token`.
/// Without `gh` or a GitHub remote it returns no PR info.
public actor GitHubStatusService {
    public typealias TokenSource = @Sendable () async throws -> String
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Keeps each request far below GitHub's node limits; 50 branches cost about 5 points.
    static let branchesPerRequest = 50
    private static let endpoint = URL(string: "https://api.github.com/graphql")!

    private let tokenSource: TokenSource
    private let transport: Transport
    private var token: String?

    public init() {
        self.init(tokenSource: GitHubToken.fromGH, transport: { try await URLSession.shared.data(for: $0) })
    }

    public init(tokenSource: @escaping TokenSource, transport: @escaping Transport) {
        self.tokenSource = tokenSource
        self.transport = transport
    }

    /// Keys are branch names; branches without a PR are absent.
    public func pullRequests(repository: GitHubRepository, branches: [String]) async throws -> [String: PullRequestInfo] {
        let unique = Array(Set(branches)).sorted()
        var result: [String: PullRequestInfo] = [:]
        for start in stride(from: 0, to: unique.count, by: Self.branchesPerRequest) {
            let chunk = Array(unique[start..<min(start + Self.branchesPerRequest, unique.count)])
            let query = PullRequestQuery(repository: repository, branches: chunk)
            result.merge(try await fetchRefreshingToken(query)) { $1 }
        }
        return result
    }

    /// How long to wait before polling a PR again.
    public static func pollInterval(for pullRequest: PullRequestInfo?, sessionIsIdle: Bool) -> Duration {
        if sessionIsIdle { return .seconds(300) }
        guard let pullRequest else { return .seconds(60) }
        switch pullRequest.state {
        case .merged, .closed:
            return .seconds(300)
        case .open where pullRequest.isDraft:
            return .seconds(60)
        case .open:
            let green = pullRequest.checks.map { $0.state == .success } ?? true
            return pullRequest.reviewDecision == .approved && green ? .seconds(15) : .seconds(30)
        }
    }

    private func fetchRefreshingToken(_ query: PullRequestQuery) async throws -> [String: PullRequestInfo] {
        do {
            return try await fetch(query, token: currentToken())
        } catch GitHubError.unauthorized {
            token = nil
            return try await fetch(query, token: currentToken())
        }
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        let fresh = try await tokenSource()
        token = fresh
        return fresh
    }

    private func fetch(_ query: PullRequestQuery, token: String) async throws -> [String: PullRequestInfo] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = query.body
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Constellation", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        switch http.statusCode {
        case 200:
            do {
                return try query.decode(data)
            } catch GitHubError.rateLimited {
                throw GitHubError.rateLimited(retryAfter: Self.retryDelay(http) ?? .seconds(60))
            }
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if let delay = Self.retryDelay(http) { throw GitHubError.rateLimited(retryAfter: delay) }
            if http.statusCode == 429 { throw GitHubError.rateLimited(retryAfter: .seconds(60)) }
            throw GitHubError.requestFailed(status: http.statusCode)
        default:
            throw GitHubError.requestFailed(status: http.statusCode)
        }
    }

    /// `retry-after` for secondary limits, else the primary limit's reset time once it is exhausted.
    static func retryDelay(_ response: HTTPURLResponse, now: Date = .now) -> Duration? {
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(Int.init) {
            return .seconds(retryAfter)
        }
        guard response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
              let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        else { return nil }
        return .seconds(max(1, reset - now.timeIntervalSince1970))
    }
}

public enum GitHubError: Error, Hashable, Sendable {
    /// `gh` is missing or not logged in.
    case noToken
    case unauthorized
    case requestFailed(status: Int)
    case rateLimited(retryAfter: Duration)
    case repositoryNotFound
    case invalidResponse
    case graphQL(String)
}

enum GitHubToken {
    static func fromGH() async throws -> String {
        guard let gh = Subprocess.locate("gh"),
              let token = try? await Subprocess.run(gh, ["auth", "token", "--hostname", "github.com"]),
              !token.isEmpty
        else { throw GitHubError.noToken }
        return token
    }
}
