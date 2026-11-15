import ConstellationProcess
import Foundation

/// What a session's PR tab shows: each check, and what reviewers wrote. Fetched through `gh` when
/// the tab opens, not polled, so the poller's one cheap query stays as it is.
public struct PullRequestDetails: Hashable, Sendable {
    public struct Check: Hashable, Sendable, Identifiable {
        public enum Outcome: String, Hashable, Sendable {
            case pass, fail, pending, skipping, cancel
        }

        public var name: String
        public var workflow: String
        public var outcome: Outcome
        public var link: URL?

        public var id: String { workflow + "/" + name }

        /// The Actions run and job a check's link points at, for its log.
        public var job: (run: String, job: String)? {
            guard let link, let match = link.absoluteString.firstMatch(of: /\/actions\/runs\/(\d+)\/job\/(\d+)/) else { return nil }
            return (String(match.output.1), String(match.output.2))
        }
    }

    public struct Comment: Hashable, Sendable, Identifiable {
        public var author: String
        public var body: String
        /// The file and line an inline review comment is on.
        public var path: String?
        public var line: Int?
        public var link: URL?
        /// A review's verdict: CHANGES_REQUESTED, APPROVED or COMMENTED.
        public var verdict: String?

        public var id: String { link?.absoluteString ?? "\(author)\(path ?? "")\(line ?? 0)\(body.prefix(40))" }
    }

    public struct Failure: Error {
        public var message: String
    }

    public var checks: [Check]
    public var comments: [Comment]

    public var failing: [Check] { checks.filter { $0.outcome == .fail } }

    public static func fetch(number: Int, repository: GitHubRepository) async throws -> PullRequestDetails {
        guard let gh = Subprocess.locate("gh") else { throw Failure(message: "gh isn't installed.") }
        let repo = "\(repository.owner)/\(repository.name)"
        async let checks = run(gh, ["pr", "checks", "\(number)", "--repo", repo, "--json", "name,bucket,link,workflow"])
        async let view = run(gh, ["pr", "view", "\(number)", "--repo", repo, "--json", "reviews,comments"])
        async let inline = run(gh, ["api", "repos/\(repo)/pulls/\(number)/comments", "--paginate"])
        let (checkRows, viewJSON, inlineJSON) = try await (checks, view, inline)
        return PullRequestDetails(
            checks: parseChecks(checkRows.output),
            comments: parseComments(view: viewJSON.output, inline: inlineJSON.output)
        )
    }

    /// The failed steps' log of a check run by GitHub Actions, its last `lines` lines.
    public static func failureLog(of check: Check, repository: GitHubRepository, lines: Int = 150) async throws -> String {
        guard let gh = Subprocess.locate("gh"), let job = check.job else { throw Failure(message: "No log for \(check.name).") }
        let result = try await run(gh, ["run", "view", job.run, "--job", job.job, "--repo", "\(repository.owner)/\(repository.name)", "--log-failed"])
        guard result.status == 0 else { throw Failure(message: result.output) }
        return cleanLog(result.output, lines: lines)
    }

    // MARK: Parsing

    static func parseChecks(_ json: String) -> [Check] {
        struct Row: Decodable { var name: String; var bucket: String; var link: String?; var workflow: String? }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(json.utf8))) ?? []
        let order: [Check.Outcome] = [.fail, .pending, .cancel, .pass, .skipping]
        return rows.map {
            Check(name: $0.name, workflow: $0.workflow ?? "", outcome: Check.Outcome(rawValue: $0.bucket) ?? .pending, link: $0.link.flatMap(URL.init(string:)))
        }
        .sorted { (order.firstIndex(of: $0.outcome) ?? 0, $0.name) < (order.firstIndex(of: $1.outcome) ?? 0, $1.name) }
    }

    static func parseComments(view: String, inline: String) -> [Comment] {
        struct Author: Decodable { var login: String }
        struct Review: Decodable { var author: Author?; var body: String; var state: String }
        struct Remark: Decodable { var author: Author?; var body: String; var url: String? }
        struct View: Decodable { var reviews: [Review]; var comments: [Remark] }
        struct User: Decodable { var login: String }
        struct Inline: Decodable { var user: User?; var body: String; var path: String?; var line: Int?; var original_line: Int?; var html_url: String? }

        let decoded = try? JSONDecoder().decode(View.self, from: Data(view.utf8))
        let reviews = (decoded?.reviews ?? []).compactMap { review -> Comment? in
            // An approval with no words still says something; an empty comment review doesn't.
            guard !review.body.isEmpty || review.state != "COMMENTED" else { return nil }
            return Comment(author: review.author?.login ?? "ghost", body: review.body, verdict: review.state)
        }
        let remarks = (decoded?.comments ?? []).map {
            Comment(author: $0.author?.login ?? "ghost", body: $0.body, link: $0.url.flatMap(URL.init(string:)))
        }
        let inlines = ((try? JSONDecoder().decode([Inline].self, from: Data(inline.utf8))) ?? []).map {
            Comment(author: $0.user?.login ?? "ghost", body: $0.body, path: $0.path, line: $0.line ?? $0.original_line, link: $0.html_url.flatMap(URL.init(string:)))
        }
        return reviews + inlines + remarks
    }

    /// `gh run view --log-failed` prints "job, tab, step, tab, timestamp, text"; this keeps the text.
    static func cleanLog(_ log: String, lines: Int) -> String {
        let text = log.split(separator: "\n").map { line -> String in
            var text = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init) ?? String(line)
            text = text.replacing("\u{FEFF}", with: "")
            text = text.replacing(/^\d{4}-\d\d-\d\dT[\d:.]+Z ?/, with: "")
            return text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
        }
        return text.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads all of stdout before waiting, so a long log can't fill the pipe and stall. `gh pr checks`
    /// exits non-zero while checks fail or wait, with its JSON all the same.
    private static func run(_ gh: URL, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = try ChildProcess(executable: gh, arguments: arguments, environment: ProcessInfo.processInfo.environment, standardError: .null)
        let output = await Task.detached { process.standardOutput!.readDataToEndOfFile() }.value
        return (await process.waitForExit(), String(decoding: output, as: UTF8.self))
    }
}
