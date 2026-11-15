import Foundation
import Testing
@testable import ConstellationGit

@Suite struct CommitTests {
    @Test func listsEachChangedFileWithItsKind() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try repo.write("old.txt", "old\n")
        try repo.write("gone.txt", "bye\n")
        try await repo.commitAll("Add files")
        try repo.write("README.md", "changed\n")
        try repo.write("Sources/new/a.swift", "let a = 1\n")
        try FileManager.default.removeItem(at: repo.root.appending(path: "gone.txt"))
        try await repo.git("mv", "old.txt", "renamed.txt")

        let changes = try await repo.service.workingChanges(in: repo.root)
        #expect(changes == [
            WorkingChange(path: "README.md", kind: .modified),
            WorkingChange(path: "Sources/new/a.swift", kind: .untracked),
            WorkingChange(path: "gone.txt", kind: .deleted),
            WorkingChange(path: "renamed.txt", originalPath: "old.txt", kind: .renamed),
        ])
    }

    @Test func commitsOnlyTheChosenFiles() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("keep.txt", "not yet\n", in: worktree.path)
        try repo.write("ship [1].txt", "ship\n", in: worktree.path)
        try repo.write("staged.txt", "staged by the agent\n", in: worktree.path)
        try await repo.git("add", "staged.txt", in: worktree.path)
        try FileManager.default.removeItem(at: worktree.path.appending(path: "README.md"))

        let chosen = try await repo.service.workingChanges(in: worktree.path).filter { ["ship [1].txt", "README.md"].contains($0.path) }
        #expect(chosen.count == 2)
        let hash = try await repo.service.commit(chosen, message: "  Ship it\n\nWith a body.\n", in: worktree.path)

        #expect(try await repo.git("rev-parse", "--short", "HEAD", in: worktree.path) == hash)
        #expect(try await repo.git("log", "-1", "--format=%B", in: worktree.path) == "Ship it\n\nWith a body.")
        let committed = try await repo.git("show", "--name-status", "--format=", "HEAD", in: worktree.path)
        #expect(committed == "D\tREADME.md\nA\tship [1].txt")
        let left = try await repo.service.workingChanges(in: worktree.path).map(\.path)
        #expect(left == ["keep.txt", "staged.txt"])
    }

    @Test func commitsARenameAsOneChange() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        try await repo.git("mv", "README.md", "READ.md")

        let changes = try await repo.service.workingChanges(in: repo.root)
        try await repo.service.commit(changes, message: "Rename", in: repo.root)
        #expect(try await repo.service.workingChanges(in: repo.root).isEmpty)
        #expect(try await repo.git("show", "--name-status", "--format=", "-M", "HEAD") == "R100\tREADME.md\tREAD.md")
    }

    @Test func refusesAnEmptyMessageOrNoFiles() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        let changes = try await repo.service.workingChanges(in: repo.root)

        await #expect(throws: PublishError.emptyCommitMessage) {
            try await repo.service.commit(changes, message: " \n", in: repo.root)
        }
        await #expect(throws: PublishError.nothingToCommit) {
            try await repo.service.commit([], message: "Message", in: repo.root)
        }
    }

    @Test func aFailingHookShowsItsOutput() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let hooks = repo.sandbox.appending(path: "hooks", directoryHint: .isDirectory)
        try repo.write("hooks/pre-commit", "#!/bin/sh\necho 'lint failed' >&2\nexit 1\n", in: repo.sandbox)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appending(path: "pre-commit").path(percentEncoded: false))
        try await repo.git("config", "core.hooksPath", hooks.path(percentEncoded: false))
        try repo.write("a.txt", "a\n")

        let changes = try await repo.service.workingChanges(in: repo.root)
        do {
            try await repo.service.commit(changes, message: "Message", in: repo.root)
            Issue.record("The commit should have failed")
        } catch let error as GitError {
            #expect(error.message == "lint failed")
        }
    }
}

@Suite struct PushTests {
    @Test func pushesANewBranchAndSetsItsUpstream() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("a.txt", "a\n", in: worktree.path)
        try await repo.commitAll("One", in: worktree.path)
        try repo.write("b.txt", "b\n", in: worktree.path)
        try await repo.commitAll("Two", in: worktree.path)

        let before = try await repo.service.pushState(of: worktree.path, base: "main")
        #expect(before == PushState(branch: worktree.branch, hasUpstream: false, hasOrigin: true, unpushedCommits: 2, uncommittedFiles: 0))
        #expect(before.needsPush)

        try await repo.service.push(branch: worktree.branch, in: worktree.path)

        let head = try await repo.git("rev-parse", "HEAD", in: worktree.path)
        #expect(try await repo.git("rev-parse", "refs/heads/\(worktree.branch)", in: repo.remote) == head)
        let after = try await repo.service.pushState(of: worktree.path, base: "main")
        #expect(after.hasUpstream && after.unpushedCommits == 0 && !after.needsPush)
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "@{upstream}", in: worktree.path) == "origin/\(worktree.branch)")
    }

    @Test func countsCommitsAheadOfTheUpstream() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("Ahead")
        try repo.write("b.txt", "dirty\n")

        let state = try await repo.service.pushState(of: repo.root, base: "main")
        #expect(state == PushState(branch: "main", hasUpstream: true, hasOrigin: true, unpushedCommits: 1, uncommittedFiles: 1))
    }

    @Test func withoutOriginThePushFailsWithGitsMessage() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        #expect(try await repo.service.pushState(of: repo.root, base: "main").hasOrigin == false)

        do {
            try await repo.service.push(branch: "main", in: repo.root)
            Issue.record("The push should have failed")
        } catch let error as GitError {
            #expect(error.message.contains("origin"))
        }
    }
}

@Suite struct PullRequestTests {
    @Test func diffStatCoversCommitsSinceTheBase() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("a.txt", "one\ntwo\n", in: worktree.path)
        try await repo.commitAll("Add a", in: worktree.path)
        try repo.write("uncommitted.txt", "x\n", in: worktree.path)

        let stat = try await repo.service.diffStat(in: worktree.path, against: "main")
        #expect(stat.contains("a.txt | 2 ++"))
        #expect(stat.contains("1 file changed, 2 insertions(+)"))
        #expect(!stat.contains("uncommitted"))
    }

    @Test func createsADraftWithGH() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let gh = try StubGH(in: repo.sandbox, stdout: "Creating draft pull request\nhttps://github.com/acme/app/pull/7\n")

        let draft = PullRequestDraft(title: "Add a thing", body: "## Summary\n\n- Did it", base: "main", head: "constellation/thing")
        let url = try await repo.service.createPullRequest(draft, in: repo.root, gh: gh.executable)

        #expect(url == URL(string: "https://github.com/acme/app/pull/7"))
        #expect(try gh.arguments() == [
            "pr", "create", "--title", "Add a thing", "--body", "## Summary\n\n- Did it",
            "--base", "main", "--head", "constellation/thing", "--draft",
        ])
        #expect(try gh.environment().contains("GH_PROMPT_DISABLED=1"))
    }

    @Test func aReadyPRLeavesOutDraft() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let gh = try StubGH(in: repo.sandbox, stdout: "https://github.com/acme/app/pull/8\n")

        let draft = PullRequestDraft(title: "T", body: "", base: "main", head: "feature", isDraft: false)
        _ = try await repo.service.createPullRequest(draft, in: repo.root, gh: gh.executable)
        #expect(try !gh.arguments().contains("--draft"))
    }

    @Test func ghFailureCarriesItsMessage() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let gh = try StubGH(in: repo.sandbox, stderr: "a pull request for branch \"feature\" already exists", status: 1)

        let draft = PullRequestDraft(title: "T", body: "B", base: "main", head: "feature")
        do {
            _ = try await repo.service.createPullRequest(draft, in: repo.root, gh: gh.executable)
            Issue.record("gh should have failed")
        } catch let error as GitError {
            #expect(error.message == "a pull request for branch \"feature\" already exists")
        }
    }
}

@Suite struct PublishTextTests {
    @Test func commitMessageIsTheTitleThenTheLastOutcome() {
        #expect(PublishText.commitMessage(title: "Fix the login redirect…", outcome: "Redirect now keeps the query string.")
            == "Fix the login redirect\n\nRedirect now keeps the query string.")
        #expect(PublishText.commitMessage(title: "Fix it", outcome: nil) == "Fix it")
        #expect(PublishText.commitMessage(title: "Fix it", outcome: "fix it") == "Fix it")
        #expect(PublishText.commitMessage(title: "", outcome: "Did it") == "Did it")
    }

    @Test func pullRequestBodyListsOutcomesThenTheDiffStat() {
        let body = PublishText.pullRequestBody(
            outcomes: ["Added the thing.", " Added the thing. ", "Tests pass.\nAll of them."],
            diffStat: " a.txt | 2 ++\n 1 file changed, 2 insertions(+)\n"
        )
        #expect(body == """
            ## Summary

            - Added the thing.
            - Tests pass.
              All of them.

            ## Changes

            ```
             a.txt | 2 ++
             1 file changed, 2 insertions(+)
            ```
            """)
        #expect(PublishText.pullRequestBody(outcomes: [], diffStat: "") == "")
    }
}

/// A fake `gh` that records its arguments and environment, then prints what it was told to.
private struct StubGH {
    let executable: URL
    private let folder: URL

    init(in sandbox: URL, stdout: String = "", stderr: String = "", status: Int32 = 0) throws {
        folder = sandbox.appending(path: "gh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try stdout.write(to: folder.appending(path: "stdout"), atomically: true, encoding: .utf8)
        try stderr.write(to: folder.appending(path: "stderr"), atomically: true, encoding: .utf8)
        executable = folder.appending(path: "gh")
        let dir = folder.path(percentEncoded: false)
        let script = """
            #!/bin/sh
            for arg in "$@"; do printf '%s\\0' "$arg"; done > '\(dir)/args'
            env > '\(dir)/env'
            cat '\(dir)/stdout'
            cat '\(dir)/stderr' >&2
            exit \(status)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    func arguments() throws -> [String] {
        let data = try Data(contentsOf: folder.appending(path: "args"))
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func environment() throws -> [String] {
        try String(contentsOf: folder.appending(path: "env"), encoding: .utf8).components(separatedBy: "\n")
    }
}

extension TestRepository {
    /// `GitService` runs git with the real global config, so commits it makes need a local identity
    /// and no signing or hooks.
    func configureCommitter() async throws {
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")
        try await git("config", "core.hooksPath", "/dev/null")
    }
}
