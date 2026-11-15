import Foundation
import Testing
@testable import ConstellationGit

@Suite struct MergingTests {
    @Test func fastForwardsTheCheckoutOfBase() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("test.js", "ok\n", in: worktree.path)
        try await repo.commitAll("Add a test", in: worktree.path)

        let preview = try await repo.service.mergePreview(of: worktree.path, into: "main")
        #expect(preview == MergePreview(branch: worktree.branch, base: "main", commits: 1, uncommittedFiles: 0, conflicts: []))
        #expect(try await repo.service.merge(worktree.branch, into: "main", in: worktree.path) == .fastForward)

        #expect(try await repo.git("rev-parse", "main") == repo.git("rev-parse", worktree.branch))
        #expect(try String(contentsOf: repo.root.appending(path: "test.js"), encoding: .utf8) == "ok\n")
        #expect(try await repo.git("status", "--porcelain").isEmpty)
        #expect(try await repo.service.status(of: worktree.path, defaultBranch: "main").isMerged)
    }

    @Test func makesAMergeCommitWithoutTouchingTheProjectCheckout() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("test.js", "ok\n", in: worktree.path)
        try await repo.commitAll("Add a test", in: worktree.path)
        try repo.write("other.txt", "on main\n")
        try await repo.commitAll("Move main on")
        try await repo.git("checkout", "--quiet", "-b", "elsewhere")
        try repo.write("README.md", "unsaved\n")
        let (oldMain, tip) = (try await repo.git("rev-parse", "main"), try await repo.git("rev-parse", worktree.branch))

        #expect(try await repo.service.merge(worktree.branch, into: "main", in: worktree.path) == .mergeCommit)

        #expect(try await repo.git("rev-list", "--parents", "-1", "main") == "\(try await repo.git("rev-parse", "main")) \(oldMain) \(tip)")
        #expect(try await repo.git("log", "-1", "--format=%s", "main") == "Merge branch '\(worktree.branch)'")
        #expect(try await repo.git("ls-tree", "--name-only", "main") == "README.md\nother.txt\ntest.js")
        #expect(try await repo.git("branch", "--show-current") == "elsewhere")
        #expect(try await repo.git("status", "--porcelain") == "M README.md")
        #expect(try await repo.service.isMerged(worktree.branch, into: "main", projectRoot: repo.root))
    }

    @Test func findsConflictsAndLeavesEverythingAsItWas() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("README.md", "from the branch\n", in: worktree.path)
        try await repo.commitAll("Edit the readme", in: worktree.path)
        try repo.write("README.md", "from main\n")
        try await repo.commitAll("Edit the readme on main")
        let (oldMain, tip) = (try await repo.git("rev-parse", "main"), try await repo.git("rev-parse", worktree.branch))

        let preview = try await repo.service.mergePreview(of: worktree.path, into: "main")
        #expect(preview.conflicts == ["README.md"])
        #expect(!preview.canMerge)
        await #expect(throws: MergeError.conflicts(["README.md"])) {
            try await repo.service.merge(worktree.branch, into: "main", in: worktree.path)
        }

        #expect(try await repo.git("rev-parse", "main") == oldMain)
        #expect(try await repo.git("rev-parse", worktree.branch) == tip)
        #expect(try await repo.git("status", "--porcelain").isEmpty)
        #expect(try await repo.git("status", "--porcelain", in: worktree.path).isEmpty)
    }

    @Test func refusesWhenTheCheckoutOfBaseHasChanges() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try await repo.configureCommitter()
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("test.js", "ok\n", in: worktree.path)
        try await repo.commitAll("Add a test", in: worktree.path)
        try repo.write("README.md", "unsaved\n")
        let oldMain = try await repo.git("rev-parse", "main")

        await #expect(throws: MergeError.baseCheckoutDirty("main", repo.root)) {
            try await repo.service.merge(worktree.branch, into: "main", in: worktree.path)
        }
        #expect(try await repo.git("rev-parse", "main") == oldMain)
    }
}
