import Foundation

/// What restoring a checkpoint would undo.
public struct CheckpointLoss: Hashable, Sendable {
    /// Files added, changed or deleted since the checkpoint, relative to the worktree.
    public var files: [String]
    /// Commits made on the branch since the checkpoint.
    public var commits: Int

    public init(files: [String], commits: Int) {
        self.files = files
        self.commits = commits
    }

    public var isEmpty: Bool { files.isEmpty && commits == 0 }
}

/// Turn checkpoints: commits of the whole worktree kept under hidden refs, made without touching
/// HEAD, the index or any file, so Rewind can put the files back.
extension GitService {
    public static let checkpointRefPrefix = "refs/constellation"

    /// Commits the worktree as it is, untracked files included and ignored ones left out, and keeps
    /// it under `refs/constellation/<session>/<commit>`, so snapshots taken at once never share a
    /// ref. Its parent is HEAD at the time.
    public func snapshot(_ worktree: URL, session: UUID) async throws -> String {
        let tree = try await writeTree(of: worktree)
        let head = try await headCommit(of: worktree)
        let author = [
            "GIT_AUTHOR_NAME": "Constellation", "GIT_AUTHOR_EMAIL": "constellation@localhost",
            "GIT_COMMITTER_NAME": "Constellation", "GIT_COMMITTER_EMAIL": "constellation@localhost",
        ]
        let parent = head.map { ["-p", $0] } ?? []
        let commit = try await git(["commit-tree", "--no-gpg-sign", tree] + parent + ["-m", "Constellation checkpoint"], in: worktree, environment: author).stdoutText.trimmed
        try await git(["update-ref", "\(Self.checkpointPrefix(session))/\(commit)", commit], in: worktree)
        return commit
    }

    /// The files that differ from the checkpoint now, and the commits made since it.
    public func loss(restoring commit: String, in worktree: URL) async throws -> CheckpointLoss {
        let now = try await writeTree(of: worktree)
        let names = try await git(["diff", "--name-only", "-z", "--no-renames", commit, now], in: worktree).stdoutText
        var commits = 0
        if let parent = try await parent(of: commit, in: worktree) {
            commits = Int(try await git(["rev-list", "--count", "\(parent)..HEAD"], in: worktree).stdoutText.trimmed) ?? 0
        }
        return CheckpointLoss(files: Self.nulSeparated(names), commits: commits)
    }

    /// Puts the worktree's files back as they were at the checkpoint, and moves the branch back to
    /// where HEAD was then. Ignored files are left alone; the index ends up matching HEAD.
    public func restore(_ commit: String, in worktree: URL) async throws {
        if let parent = try await parent(of: commit, in: worktree) {
            try await git(["reset", "--quiet", parent], in: worktree)
        }
        let wanted = Set(Self.nulSeparated(try await git(["ls-tree", "-r", "-z", "--name-only", commit], in: worktree).stdoutText))
        let present = Self.nulSeparated(try await git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: worktree).stdoutText)
        for path in present where !wanted.contains(path) {
            try? FileManager.default.removeItem(at: worktree.appending(path: path))
        }
        guard !wanted.isEmpty else { return }
        try await git(["checkout", commit, "--", ":/"], in: worktree)
        _ = try await run(["reset", "--quiet"], in: worktree)
    }

    /// Removes a session's checkpoint refs. Best effort.
    public func deleteCheckpoints(session: UUID, in directory: URL) async {
        guard let refs = try? await git(["for-each-ref", "--format=%(refname)", Self.checkpointPrefix(session) + "/"], in: directory).stdoutText else { return }
        for ref in refs.split(whereSeparator: \.isNewline) {
            _ = try? await run(["update-ref", "-d", String(ref)], in: directory)
        }
    }

    /// Nil before the first commit.
    public func headCommit(of directory: URL) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory)
        return output.status == 0 ? output.stdoutText.trimmed : nil
    }

    static func checkpointPrefix(_ session: UUID) -> String {
        "\(checkpointRefPrefix)/\(session.uuidString.lowercased())"
    }

    /// The worktree's tree, written through a scratch copy of the index so the real one is untouched.
    private func writeTree(of worktree: URL) async throws -> String {
        let indexPath = try await git(["rev-parse", "--git-path", "index"], in: worktree).stdoutText.trimmed
        let index = indexPath.hasPrefix("/") ? URL(filePath: indexPath) : worktree.appending(path: indexPath)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "constellation-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.copyItem(at: index, to: scratch)
        let environment = ["GIT_INDEX_FILE": scratch.path(percentEncoded: false)]
        try await git(["add", "--all", "--", ":/"], in: worktree, environment: environment)
        return try await git(["write-tree"], in: worktree, environment: environment).stdoutText.trimmed
    }

    private func parent(of commit: String, in directory: URL) async throws -> String? {
        let output = try await run(["rev-parse", "--verify", "--quiet", "\(commit)^"], in: directory)
        return output.status == 0 ? output.stdoutText.trimmed : nil
    }

    private static func nulSeparated(_ text: String) -> [String] {
        text.split(separator: "\0").map(String.init)
    }
}
