import Foundation

/// Commit, push and pull request creation for a session's worktree. No model calls; `gh` creates the PR.
extension GitService {
    // MARK: Commit

    /// Uncommitted changes, one entry per file: staged, unstaged and untracked (each file in a new folder).
    public func workingChanges(in worktree: URL) async throws -> [WorkingChange] {
        let output = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: worktree)
        return Self.parseWorkingChanges(output.stdoutText)
    }

    static func parseWorkingChanges(_ porcelain: String) -> [WorkingChange] {
        var changes: [WorkingChange] = []
        var records = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { continue }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            let kind = WorkingChange.Kind(statusCode: code)
            // A rename or copy record is followed by its original path.
            let original = code.contains("R") || code.contains("C") ? records.next().map(String.init) : nil
            changes.append(WorkingChange(path: path, originalPath: original, kind: kind))
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// Stages exactly the chosen files (deletions and renames included) and commits only those,
    /// leaving anything else that was staged as it was. Returns the new commit's short hash.
    @discardableResult
    public func commit(_ changes: [WorkingChange], message: String, in worktree: URL) async throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw PublishError.emptyCommitMessage }
        let paths = Array(Set(changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })).sorted()
        guard !paths.isEmpty else { throw PublishError.nothingToCommit }

        let onDisk = paths.filter { FileManager.default.fileExists(atPath: worktree.appending(path: $0).path(percentEncoded: false)) }
        let removed = paths.filter { !onDisk.contains($0) }
        if !onDisk.isEmpty {
            try await git(["--literal-pathspecs", "add", "--all", "--"] + onDisk, in: worktree)
        }
        if !removed.isEmpty {
            try await git(["--literal-pathspecs", "rm", "--cached", "--quiet", "--ignore-unmatch", "--"] + removed, in: worktree)
        }
        try await git(["--literal-pathspecs", "commit", "--quiet", "--message", message, "--"] + paths, in: worktree)
        return try await git(["rev-parse", "--short", "HEAD"], in: worktree).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Push

    /// What a push would send: the branch, its upstream if any, and how many commits are not on it.
    public func pushState(of worktree: URL, base: String) async throws -> PushState {
        let status = Self.parseStatus(try await git(["status", "--porcelain=v2", "--branch", "-z"], in: worktree).stdoutText)
        let remotes = try await git(["remote"], in: worktree).stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        var unpushed = status.ahead
        if !status.hasUpstream {
            let range = try await refExists("refs/heads/\(base)", in: worktree) ? "\(base)..HEAD" : "HEAD"
            let count = try await run(["rev-list", "--count", range], in: worktree)
            unpushed = Int(String(decoding: count.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return PushState(
            branch: status.branch,
            hasUpstream: status.hasUpstream,
            hasOrigin: remotes.contains("origin"),
            unpushedCommits: unpushed,
            uncommittedFiles: status.dirtyFileCount
        )
    }

    /// `git push -u origin <branch>`. No prompts: a remote that needs credentials fails instead of hanging.
    public func push(branch: String, remote: String = "origin", in worktree: URL) async throws {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { throw GitError.invalidBranchName(branch) }
        let arguments = ["push", "--porcelain", "-u", remote, "refs/heads/\(branch):refs/heads/\(branch)"]
        let output = try await run(arguments, in: worktree, timeout: .seconds(120))
        guard output.status == 0 else {
            throw GitError.commandFailed(arguments: arguments, status: output.status, stderr: output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Pull request

    /// `git diff --stat` from the merge base with `base` to HEAD: what the PR will contain.
    public func diffStat(in worktree: URL, against base: String) async throws -> String {
        let mergeBase = try await mergeBase(base, in: worktree)
        return try await git(["diff", "--stat", "--no-color", mergeBase, "HEAD"], in: worktree).stdoutText
            .trimmingCharacters(in: .newlines)
    }

    /// `gh pr create` for `head` into `base`, draft unless asked otherwise. Returns the PR's URL.
    /// The branch must be pushed first; `--head` keeps `gh` from offering to push or fork.
    public func createPullRequest(_ draft: PullRequestDraft, in worktree: URL, gh: URL) async throws -> URL {
        var arguments = ["pr", "create", "--title", draft.title, "--body", draft.body, "--base", draft.base, "--head", draft.head]
        if draft.isDraft { arguments.append("--draft") }
        let output = try await ProcessRunner.run(
            gh,
            arguments,
            in: worktree,
            environment: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GIT_TERMINAL_PROMPT": "0"],
            timeout: .seconds(120)
        )
        let stdout = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0 else {
            let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.commandFailed(arguments: ["gh", "pr", "create"], status: output.status, stderr: stderr.isEmpty ? stdout : stderr)
        }
        guard let line = stdout.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("https://") }),
              let url = URL(string: String(line))
        else { throw GitError.commandFailed(arguments: ["gh", "pr", "create"], status: 0, stderr: "gh didn't print a pull request URL.") }
        return url
    }

    /// Finds `gh` in the usual install locations, since a GUI app does not inherit the login shell's PATH.
    public nonisolated static func locateGH() -> URL? {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (["/opt/homebrew/bin", "/usr/local/bin"] + pathEntries)
            .map { URL(filePath: $0).appending(path: "gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }
}

/// One uncommitted file, as the commit sheet lists it.
public struct WorkingChange: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case modified, added, deleted, renamed, untracked, conflicted

        init(statusCode code: String) {
            if code == "??" {
                self = .untracked
            } else if code == "DD" || code == "AA" || code.contains("U") {
                self = .conflicted
            } else if code.contains("R") || code.contains("C") {
                self = .renamed
            } else if code.contains("D") {
                self = .deleted
            } else if code.hasPrefix("A") {
                self = .added
            } else {
                self = .modified
            }
        }
    }

    public var path: String
    /// Where a renamed file came from. Committing it commits the removal too.
    public var originalPath: String?
    public var kind: Kind

    public var id: String { path }

    public init(path: String, originalPath: String? = nil, kind: Kind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }
}

public struct PushState: Hashable, Sendable {
    /// Nil when HEAD is detached.
    public var branch: String?
    public var hasUpstream: Bool
    public var hasOrigin: Bool
    /// Commits ahead of the upstream, or since the base branch when there is no upstream yet.
    public var unpushedCommits: Int
    public var uncommittedFiles: Int

    public init(branch: String?, hasUpstream: Bool, hasOrigin: Bool, unpushedCommits: Int, uncommittedFiles: Int) {
        self.branch = branch
        self.hasUpstream = hasUpstream
        self.hasOrigin = hasOrigin
        self.unpushedCommits = unpushedCommits
        self.uncommittedFiles = uncommittedFiles
    }

    /// A push has something to do: a branch never pushed, or commits the upstream lacks.
    public var needsPush: Bool { !hasUpstream || unpushedCommits > 0 }
}

public struct PullRequestDraft: Hashable, Sendable {
    public var title: String
    public var body: String
    public var base: String
    public var head: String
    public var isDraft: Bool

    public init(title: String, body: String, base: String, head: String, isDraft: Bool = true) {
        self.title = title
        self.body = body
        self.base = base
        self.head = head
        self.isDraft = isDraft
    }
}

/// The pre-filled text for the commit and pull request sheets, from the session title and Outcomes.
public enum PublishText {
    /// The title as the subject line, and the last Outcome summary as the body when it adds anything.
    public static func commitMessage(title: String, outcome: String?) -> String {
        let subject = subjectLine(title)
        guard let outcome = outcome?.trimmingCharacters(in: .whitespacesAndNewlines), !outcome.isEmpty,
              outcome.caseInsensitiveCompare(subject) != .orderedSame
        else { return subject }
        return subject.isEmpty ? outcome : "\(subject)\n\n\(outcome)"
    }

    public static func pullRequestTitle(_ title: String) -> String {
        subjectLine(title)
    }

    /// Outcome summaries as a list, oldest first and without repeats, then the diff stat.
    public static func pullRequestBody(outcomes: [String], diffStat: String) -> String {
        var seen = Set<String>()
        let summaries = outcomes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var sections: [String] = []
        if !summaries.isEmpty {
            sections.append("## Summary\n\n" + summaries.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n"))
        }
        let stat = diffStat.trimmingCharacters(in: .newlines)
        if !stat.isEmpty {
            sections.append("## Changes\n\n```\n\(stat)\n```")
        }
        return sections.joined(separator: "\n\n")
    }

    /// One line, without the ellipsis a shortened session title ends in.
    static func subjectLine(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var subject = line.trimmingCharacters(in: .whitespaces)
        while subject.hasSuffix("…") { subject = String(subject.dropLast()).trimmingCharacters(in: .whitespaces) }
        return subject
    }
}

extension GitError {
    /// What to show inline when an action fails.
    public var message: String {
        switch self {
        case .commandFailed(let arguments, let status, let stderr):
            let command = arguments.first == "gh" ? "gh" : "git " + (arguments.first { !$0.hasPrefix("-") } ?? "")
            return stderr.isEmpty ? "\(command) failed with exit code \(status)." : stderr
        case .invalidBranchName(let name): return "\"\(name)\" isn't a branch that can be pushed."
        default: return String(describing: self)
        }
    }
}

public enum PublishError: Error, Hashable, Sendable {
    case emptyCommitMessage
    case nothingToCommit

    public var message: String {
        switch self {
        case .emptyCommitMessage: "Write a commit message first."
        case .nothingToCommit: "Choose at least one file to commit."
        }
    }
}
