import Foundation
@testable import ConstellationGit

/// A scratch directory holding a real git repo, a bare `origin`, a worktrees root and a DerivedData root.
struct TestRepository {
    let sandbox: URL
    let root: URL
    let remote: URL
    let worktreesRoot: URL
    let derivedDataRoot: URL

    var service: GitService {
        GitService(worktreesRoot: worktreesRoot, derivedDataRoot: derivedDataRoot)
    }

    init(defaultBranch: String = "main", withRemote: Bool = true) async throws {
        sandbox = GitService.canonical(
            FileManager.default.temporaryDirectory.appending(path: "constellation-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
        root = sandbox.appending(path: "app", directoryHint: .isDirectory)
        remote = sandbox.appending(path: "origin.git", directoryHint: .isDirectory)
        worktreesRoot = sandbox.appending(path: "worktrees", directoryHint: .isDirectory)
        derivedDataRoot = sandbox.appending(path: "DerivedData", directoryHint: .isDirectory)
        for directory in [root, worktreesRoot, derivedDataRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try await git("init", "--quiet", "-b", defaultBranch)
        try write("README.md", "hello\n")
        try await commitAll("Initial commit")
        if withRemote {
            try await Self.git(["init", "--quiet", "--bare", "-b", defaultBranch, remote.path], in: sandbox)
            try await git("remote", "add", "origin", remote.path)
            try await git("push", "--quiet", "-u", "origin", defaultBranch)
            try await git("remote", "set-head", "origin", defaultBranch)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func write(_ path: String, _ contents: String, in directory: URL? = nil) throws {
        let file = (directory ?? root).appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func commitAll(_ message: String, in directory: URL? = nil) async throws {
        try await Self.git(["add", "-A"], in: directory ?? root)
        try await Self.git(["commit", "--quiet", "-m", message], in: directory ?? root)
    }

    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
        try await Self.git(arguments, in: directory ?? root)
    }

    func branchExists(_ branch: String) async throws -> Bool {
        let output = try await ProcessRunner.run(Self.gitURL, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)
        return output.status == 0
    }

    private static let gitURL = URL(filePath: "/usr/bin/git")

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let output = try await ProcessRunner.run(
            gitURL,
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments,
            in: directory,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        )
        guard output.status == 0 else {
            throw GitError.commandFailed(arguments: arguments, status: output.status, stderr: output.stderrText)
        }
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
