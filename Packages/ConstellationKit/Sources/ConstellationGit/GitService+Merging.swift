import Foundation

/// Landing a session's branch on its base branch locally, without checking anything out in the
/// project. `git merge-tree` merges in memory, so a conflict is found before any ref or file moves.
extension GitService {
    /// What merging the worktree's branch into `base` would do.
    public func mergePreview(of worktree: URL, into base: String) async throws -> MergePreview {
        let status = Self.parseStatus(try await git(["status", "--porcelain=v2", "--branch", "-z"], in: worktree).stdoutText)
        var preview = MergePreview(branch: status.branch, base: base, commits: 0, uncommittedFiles: status.dirtyFileCount, conflicts: [])
        guard let branch = status.branch, branch != base else { return preview }
        let count = try await git(["rev-list", "--count", "refs/heads/\(base)..refs/heads/\(branch)"], in: worktree)
        preview.commits = Int(count.stdoutText.trimmed) ?? 0
        if preview.commits > 0 {
            preview.conflicts = try await mergeTree("refs/heads/\(base)", "refs/heads/\(branch)", in: worktree).conflicts
        }
        return preview
    }

    /// Moves `base` to include `branch`: a fast-forward when it can, else a merge commit. Refuses
    /// when the two conflict, leaving every ref and working tree as it was.
    @discardableResult
    public func merge(_ branch: String, into base: String, in directory: URL) async throws -> MergeKind {
        let (baseRef, branchRef) = ("refs/heads/\(base)", "refs/heads/\(branch)")
        let old = try await git(["rev-parse", "--verify", baseRef], in: directory).stdoutText.trimmed
        let tip = try await git(["rev-parse", "--verify", branchRef], in: directory).stdoutText.trimmed
        guard try await run(["merge-base", "--is-ancestor", tip, old], in: directory).status != 0 else {
            throw MergeError.nothingToMerge(branch)
        }
        let merged = try await mergeTree(old, tip, in: directory)
        guard merged.conflicts.isEmpty else { throw MergeError.conflicts(merged.conflicts) }
        let kind: MergeKind = try await run(["merge-base", "--is-ancestor", old, tip], in: directory).status == 0 ? .fastForward : .mergeCommit
        let message = "Merge branch '\(branch)'"

        // Moving the ref under a checkout of base would leave its index and files stale, so there
        // a clean checkout merges for real. Anywhere else plumbing moves the ref, guarded by its old
        // value, and nothing is checked out.
        if let checkout = try await checkout(of: base, in: directory) {
            let changes = try await git(["status", "--porcelain", "--untracked-files=no"], in: checkout).stdoutText
            guard changes.trimmed.isEmpty else { throw MergeError.baseCheckoutDirty(base, checkout) }
            try await git(["merge", "--quiet", "--no-edit"] + (kind == .fastForward ? ["--ff-only"] : ["-m", message]) + [tip], in: checkout)
        } else {
            let new = kind == .fastForward
                ? tip
                : try await git(["commit-tree", merged.tree, "-p", old, "-p", tip, "-m", message], in: directory).stdoutText.trimmed
            try await git(["update-ref", "-m", message, baseRef, new, old], in: directory)
        }
        return kind
    }

    /// `git merge-tree --write-tree`: the merged tree, and the files that conflict, if any.
    private func mergeTree(_ base: String, _ branch: String, in directory: URL) async throws -> (tree: String, conflicts: [String]) {
        let arguments = ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", base, branch]
        let output = try await run(arguments, in: directory)
        // 0 is clean, 1 conflicts; both print the tree first, then each conflicted file.
        guard output.status == 0 || output.status == 1 else {
            throw GitError.commandFailed(arguments: arguments, status: output.status, stderr: output.stderrText.trimmed)
        }
        let fields = output.stdoutText.split(separator: "\0").map(String.init)
        var seen = Set<String>()
        let conflicts = fields.dropFirst().filter { seen.insert($0).inserted }
        return (fields.first?.trimmed ?? "", output.status == 1 ? conflicts : [])
    }

    /// The worktree, main or linked, that has `branch` checked out.
    private func checkout(of branch: String, in directory: URL) async throws -> URL? {
        let output = try await git(["worktree", "list", "--porcelain", "-z"], in: directory)
        var path: URL?
        for field in output.stdoutText.split(separator: "\0") {
            if field.hasPrefix("worktree ") {
                path = Self.canonical(URL(filePath: String(field.dropFirst("worktree ".count)), directoryHint: .isDirectory))
            } else if field == "branch refs/heads/\(branch)" {
                return path
            }
        }
        return nil
    }
}

/// What the merge sheet shows before landing a branch.
public struct MergePreview: Hashable, Sendable {
    /// Nil when HEAD is detached.
    public var branch: String?
    public var base: String
    /// Commits on the branch that base lacks.
    public var commits: Int
    public var uncommittedFiles: Int
    /// Files both sides changed, so merging would conflict.
    public var conflicts: [String]

    public init(branch: String?, base: String, commits: Int, uncommittedFiles: Int, conflicts: [String]) {
        self.branch = branch
        self.base = base
        self.commits = commits
        self.uncommittedFiles = uncommittedFiles
        self.conflicts = conflicts
    }

    public var canMerge: Bool { branch != nil && commits > 0 && uncommittedFiles == 0 && conflicts.isEmpty }
}

public enum MergeKind: Hashable, Sendable {
    case fastForward, mergeCommit
}

public enum MergeError: Error, Hashable, Sendable {
    /// Merging would conflict in these files, so nothing was merged.
    case conflicts([String])
    /// The base branch is checked out here with uncommitted changes, so it can't move.
    case baseCheckoutDirty(String, URL)
    /// The branch has no commits the base lacks.
    case nothingToMerge(String)

    public var message: String {
        switch self {
        case .conflicts(let files): "Merging would conflict in \(files.joined(separator: ", "))."
        case .baseCheckoutDirty(let base, let checkout):
            "\(base) is checked out in \(checkout.path(percentEncoded: false)) with uncommitted changes. Commit them there first."
        case .nothingToMerge(let branch): "\(branch) has nothing to merge."
        }
    }
}
