import ConstellationCore
import Foundation
import Synchronization
import Testing
@testable import ConstellationGit

@Suite struct ProjectTests {
    @Test func findsTheRootFromASubfolder() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("Sources/App/main.swift", "print(1)\n")

        let root = try await repo.service.repositoryRoot(containing: repo.root.appending(path: "Sources/App"))
        #expect(root == repo.root)
    }

    @Test func rejectsAFolderOutsideAnyRepo() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }

        await #expect(throws: GitError.notARepository(repo.worktreesRoot)) {
            try await repo.service.repositoryRoot(containing: repo.worktreesRoot)
        }
    }

    @Test func defaultBranchComesFromOriginHead() async throws {
        let repo = try await TestRepository(defaultBranch: "trunk")
        defer { repo.remove() }
        try await repo.git("checkout", "--quiet", "-b", "main")

        let project = try await repo.service.inspectProject(at: repo.root)
        #expect(project.defaultBranch == "trunk")
        #expect(project.name == "app")
        #expect(project.root == repo.root)
    }

    @Test func defaultBranchFallsBackToMainThenMaster() async throws {
        let main = try await TestRepository(defaultBranch: "main", withRemote: false)
        defer { main.remove() }
        try await main.git("checkout", "--quiet", "-b", "feature")
        #expect(try await main.service.defaultBranch(of: main.root) == "main")

        let master = try await TestRepository(defaultBranch: "master", withRemote: false)
        defer { master.remove() }
        #expect(try await master.service.defaultBranch(of: master.root) == "master")

        let other = try await TestRepository(defaultBranch: "develop", withRemote: false)
        defer { other.remove() }
        #expect(try await other.service.defaultBranch(of: other.root) == "develop")
    }

    @Test func listsLocalBranchesNewestFirst() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try await repo.git("branch", "older")
        try await repo.git("checkout", "--quiet", "-b", "newer")
        // Committer dates have one-second resolution.
        try await Task.sleep(for: .seconds(1.1))
        try repo.write("CHANGES.md", "more\n")
        try await repo.commitAll("Later")

        let branches = try await repo.service.localBranches(of: repo.root)
        #expect(branches.first == "newer")
        #expect(Set(branches) == ["main", "older", "newer"])
    }

    @Test func createsARepositoryWithAnEmptyInitialCommit() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let folder = repo.sandbox.appending(path: "fresh", directoryHint: .isDirectory)

        let created = try await repo.service.createRepository(at: folder)

        #expect(created.root == folder)
        #expect(created.name == "fresh")
        #expect(try await repo.git("log", "--format=%s", in: folder) == "Initial commit")
        #expect(try await repo.git("ls-files", in: folder).isEmpty)
        await #expect(throws: (any Error).self) { try await repo.service.createRepository(at: folder) }
    }

    @Test func aFailedCreateLeavesNoFolderBehindSoItCanBeRetried() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let folder = sandbox.appending(path: "fresh", directoryHint: .isDirectory)
        let failing = GitService(gitExecutable: URL(filePath: "/usr/bin/false"))

        await #expect(throws: (any Error).self) { try await failing.createRepository(at: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }
}

@Suite struct LaunchTests {
    @Test func createsAWorktreeOnATemporaryBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }

        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        #expect(worktree.branch.wholeMatch(of: /constellation\/[0-9a-f]{8}/) != nil)
        #expect(worktree.path == repo.worktreesRoot.appending(path: "app/\(worktree.branch.dropFirst("constellation/".count))", directoryHint: .isDirectory))
        #expect(worktree.baseBranch == "main")
        #expect(FileManager.default.fileExists(atPath: worktree.path.appending(path: "README.md").path))
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "HEAD", in: worktree.path) == worktree.branch)
        let upstream = try await ProcessRunner.run(URL(filePath: "/usr/bin/git"), ["rev-parse", "--abbrev-ref", "@{upstream}"], in: worktree.path)
        #expect(upstream.status != 0)
    }

    @Test func runsTheSetupScriptAndCapturesItsOutput() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write(".constellation/setup.sh", "echo \"setting up $CONSTELLATION_WORKTREE\"\necho oops >&2\ntouch .setup-ran\n")
        try await repo.commitAll("Add setup script")

        let progress = Mutex<[WorktreeLaunchProgress]>([])
        let worktree = try await repo.service.prepareWorktree(projectRoot: repo.root, projectName: "app", base: "main") { event in
            progress.withLock { $0.append(event) }
        }

        let events = progress.withLock { $0 }
        let stages = events.compactMap { if case .stage(let stage) = $0 { stage } else { nil } }
        let output = events.compactMap { if case .setupOutput(let text) = $0 { text } else { nil } }.joined()
        #expect(stages == [.fetch, .worktree, .setup])
        #expect(output.contains("setting up \(worktree.path.path)"))
        #expect(output.contains("oops"))
        #expect(FileManager.default.fileExists(atPath: worktree.path.appending(path: ".setup-ran").path))
    }

    @Test func skipsSetupWhenThereIsNoScript() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }

        let progress = Mutex<[WorktreeLaunchProgress]>([])
        _ = try await repo.service.prepareWorktree(projectRoot: repo.root, projectName: "app", base: "main") { event in
            progress.withLock { $0.append(event) }
        }
        let stages = progress.withLock { $0 }.compactMap { if case .stage(let stage) = $0 { stage } else { nil } }
        #expect(stages == [.fetch, .worktree])
    }

    @Test func rollsBackWhenTheSetupScriptFails() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let script = repo.sandbox.appending(path: "setup.sh")
        try "echo failing\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)

        do {
            _ = try await repo.service.prepareWorktree(projectRoot: repo.root, projectName: "app", base: "main", setupScript: script)
            Issue.record("expected the launch to fail")
        } catch let error as WorktreeLaunchError {
            #expect(error.stage == .setup)
            #expect(error.underlying as? GitError == .setupScriptFailed(status: 3, output: "failing\n"))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repo.worktreesRoot.appending(path: "app").path)
        #expect(leftovers.isEmpty)
        #expect(try await repo.git("branch", "--list", "constellation/*").isEmpty)
        #expect(try await repo.git("worktree", "list", "--porcelain").components(separatedBy: "worktree ").count == 2)
    }

    @Test func cancellingDuringSetupStopsTheScriptAndRollsBack() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let script = repo.sandbox.appending(path: "setup.sh")
        try "echo started\nsleep 30\necho finished\n".write(to: script, atomically: true, encoding: .utf8)
        let service = repo.service

        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let launch = Task {
            try await service.prepareWorktree(projectRoot: repo.root, projectName: "app", base: "main", setupScript: script) { event in
                if case .setupOutput(let text) = event, text.contains("started") { startedContinuation.yield() }
            }
        }
        for await _ in started { break }
        let clock = ContinuousClock()
        let begun = clock.now
        launch.cancel()

        let result = await launch.result
        #expect(clock.now - begun < .seconds(10))
        #expect((try? result.get()) == nil)
        #expect(try await repo.git("branch", "--list", "constellation/*").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.worktreesRoot.appending(path: "app").path).isEmpty)
    }

    @Test func failsAtTheWorktreeStageForAnUnknownBase() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }

        do {
            _ = try await repo.service.prepareWorktree(projectRoot: repo.root, projectName: "app", base: "no-such-branch")
            Issue.record("expected the launch to fail")
        } catch let error as WorktreeLaunchError {
            #expect(error.stage == .worktree)
        }
        #expect(try await repo.git("branch", "--list", "constellation/*").isEmpty)
    }
}

@Suite struct RenameTests {
    @Test func renamesTheBranchAndMovesTheWorktree() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        let renamed = try await service.rename(worktree, projectRoot: repo.root, to: "fix-login-bug", moveDirectory: true)

        #expect(renamed.branch == "constellation/fix-login-bug")
        #expect(renamed.path == repo.worktreesRoot.appending(path: "app/fix-login-bug", directoryHint: .isDirectory))
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "HEAD", in: renamed.path) == "constellation/fix-login-bug")
        #expect(try await !repo.branchExists(worktree.branch))
    }

    @Test func renamesOnlyTheBranchOnceTheProviderHasStarted() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        let renamed = try await service.rename(worktree, projectRoot: repo.root, to: "add-search", moveDirectory: false)

        #expect(renamed.branch == "constellation/add-search")
        #expect(renamed.path == worktree.path)
        #expect(try await repo.git("rev-parse", "--abbrev-ref", "HEAD", in: worktree.path) == "constellation/add-search")
    }

    @Test func suffixesACollidingSlug() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let first = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        let second = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        _ = try await service.rename(first, projectRoot: repo.root, to: "tidy", moveDirectory: true)
        let renamed = try await service.rename(second, projectRoot: repo.root, to: "tidy", moveDirectory: true)

        #expect(renamed.branch == "constellation/tidy-2")
        #expect(renamed.path.lastPathComponent == "tidy-2")
    }

    @Test func rejectsAnInvalidSlugOrForeignBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        await #expect(throws: GitError.invalidBranchName("bad..slug")) {
            try await service.rename(worktree, projectRoot: repo.root, to: "bad..slug", moveDirectory: true)
        }
        let foreign = Worktree(path: repo.root, branch: "main", baseBranch: "main")
        await #expect(throws: GitError.invalidBranchName("main")) {
            try await service.rename(foreign, projectRoot: repo.root, to: "x", moveDirectory: false)
        }
    }

    @Test(arguments: [
        ("Fix the login bug on Safari please", "fix-the-login-bug-on"),
        ("  Add café search!! ", "add-cafe-search"),
        ("🚀🚀", "session"),
        ("Refactor `GitService.swift` (v2)", "refactor-gitservice-swift-v2"),
    ])
    func slugsFromPrompts(prompt: String, slug: String) {
        #expect(BranchSlug.make(from: prompt) == slug)
    }
}

@Suite struct StatusTests {
    @Test func reportsBranchDirtyCountAndUpstreamDistance() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try repo.write("b.txt", "b\n")
        try await repo.commitAll("Add files")
        try await repo.git("push", "--quiet")
        try await repo.git("reset", "--quiet", "--hard", "HEAD~1")
        try repo.write("c.txt", "c\n")
        try await repo.commitAll("Add c")
        try repo.write("README.md", "changed\n")
        try repo.write("new.txt", "new\n")

        let status = try await repo.service.status(of: repo.root, defaultBranch: "main")

        #expect(status.branch == "main")
        #expect(status.hasUpstream)
        #expect(status.ahead == 1)
        #expect(status.behind == 1)
        #expect(status.dirtyFileCount == 2)
    }

    @Test func tracksMergedAndPushedForASessionWorktree() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("feature.txt", "x\n", in: worktree.path)
        try await repo.commitAll("Feature", in: worktree.path)

        var status = try await service.status(of: worktree.path, defaultBranch: "main")
        #expect(status.branch == worktree.branch)
        #expect(!status.hasUpstream)
        #expect(!status.isMerged)
        #expect(!status.isPushed)
        #expect(WorktreeFacts(status: status, sizeInBytes: 0).hasUnpushedCommits)

        try await repo.git("push", "--quiet", "origin", worktree.branch, in: worktree.path)
        status = try await service.status(of: worktree.path, defaultBranch: "main")
        #expect(status.isPushed)
        #expect(!status.isMerged)

        try await repo.git("merge", "--quiet", "--no-edit", "--no-ff", worktree.branch)
        status = try await service.status(of: worktree.path, defaultBranch: "main")
        #expect(status.isMerged)
        #expect(try await service.isMerged(worktree.branch, into: "main", projectRoot: repo.root))
    }

    @Test func countsMergedOnOriginEvenWhenLocalDefaultIsBehind() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("feature.txt", "x\n", in: worktree.path)
        try await repo.commitAll("Feature", in: worktree.path)
        try await repo.git("push", "--quiet", "origin", "\(worktree.branch):main", in: worktree.path)
        try await repo.git("fetch", "--quiet")

        #expect(try await service.isMerged(worktree.branch, into: "main", projectRoot: repo.root))
    }

    @Test func parsesPorcelainRecords() {
        let porcelain = [
            "# branch.oid 1234",
            "# branch.head (detached)",
            "1 .M N... 100644 100644 100644 a b README.md",
            "2 R. N... 100644 100644 100644 a b R100 new.txt",
            "old.txt",
            "? untracked.txt",
            "",
        ].joined(separator: "\0")

        let status = GitService.parseStatus(porcelain)
        #expect(status.branch == nil)
        #expect(status.dirtyFileCount == 3)
        #expect(!status.hasUpstream)
    }
}

@Suite struct DiffTests {
    @Test func listsCommittedStagedUnstagedAndUntrackedFiles() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("Sources/committed.swift", "1\n", in: worktree.path)
        try await repo.commitAll("Commit", in: worktree.path)
        try repo.write("staged.txt", "s\n", in: worktree.path)
        try await repo.git("add", "staged.txt", in: worktree.path)
        try repo.write("README.md", "edited\n", in: worktree.path)
        try repo.write("untracked file.txt", "u\n", in: worktree.path)
        try repo.write("main-only.txt", "m\n")
        try await repo.commitAll("Advance main")

        let files = try await service.changedFiles(in: worktree.path, against: "main")
        #expect(files == ["README.md", "Sources/committed.swift", "staged.txt", "untracked file.txt"])

        let diff = try await service.unifiedDiff(in: worktree.path, against: "main")
        #expect(diff.contains("+edited"))
        #expect(diff.contains("Sources/committed.swift"))
        #expect(!diff.contains("main-only.txt"))
    }
}

@Suite struct CleanupTests {
    @Test func neverRemovesTheProjectRootOrAForeignFolder() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let stranger = repo.worktreesRoot.appending(path: "app/stranger", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        await #expect(throws: GitError.refusedToRemove(repo.root)) {
            try await service.removeWorktree(repo.root, projectRoot: repo.root, force: true)
        }
        await #expect(throws: GitError.refusedToRemove(stranger)) {
            try await service.removeWorktree(stranger, projectRoot: repo.root, force: true)
        }
        #expect(FileManager.default.fileExists(atPath: repo.root.appending(path: "README.md").path))
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    @Test func refusesToRemoveTheMainWorktreeFromALinkedOne() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        await #expect(throws: GitError.refusedToRemove(repo.root)) {
            try await service.removeWorktree(repo.root, projectRoot: worktree.path, force: true)
        }
    }

    @Test func removesAWorktreeAndOnlyForcesWhenAsked() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("scratch.txt", "dirty\n", in: worktree.path)

        await #expect(throws: GitError.self) {
            try await service.removeWorktree(worktree.path, projectRoot: repo.root, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path.path))

        try await service.removeWorktree(worktree.path, projectRoot: repo.root, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
    }

    @Test func prunesAWorktreeDeletedByHand() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try FileManager.default.removeItem(at: worktree.path)

        try await service.removeWorktree(worktree.path, projectRoot: repo.root, force: false)
        #expect(!(try await repo.git("worktree", "list")).contains(worktree.path.lastPathComponent))
    }

    @Test func refusesToDeleteAnUnmergedUnpushedBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("work.txt", "precious\n", in: worktree.path)
        try await repo.commitAll("Unpushed work", in: worktree.path)
        try await service.removeWorktree(worktree.path, projectRoot: repo.root, force: false)

        await #expect(throws: GitError.refusedToDeleteBranch(worktree.branch)) {
            try await service.deleteBranch(worktree.branch, defaultBranch: "main", projectRoot: repo.root)
        }
        #expect(try await repo.branchExists(worktree.branch))
    }

    @Test func deletesAMergedOrPushedBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service

        let merged = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("merged.txt", "m\n", in: merged.path)
        try await repo.commitAll("Merged work", in: merged.path)
        try await service.removeWorktree(merged.path, projectRoot: repo.root, force: false)
        try await repo.git("merge", "--quiet", "--no-edit", merged.branch)
        try await service.deleteBranch(merged.branch, defaultBranch: "main", projectRoot: repo.root)
        #expect(try await !repo.branchExists(merged.branch))

        let pushed = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("pushed.txt", "p\n", in: pushed.path)
        try await repo.commitAll("Pushed work", in: pushed.path)
        try await repo.git("push", "--quiet", "origin", pushed.branch, in: pushed.path)
        try await service.removeWorktree(pushed.path, projectRoot: repo.root, force: false)
        try await service.deleteBranch(pushed.branch, defaultBranch: "main", projectRoot: repo.root)
        #expect(try await !repo.branchExists(pushed.branch))
    }

    @Test func neverDeletesABranchConstellationDidNotCreate() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try await repo.git("branch", "feature")

        await #expect(throws: GitError.refusedToDeleteBranch("feature")) {
            try await repo.service.deleteBranch("feature", defaultBranch: "main", projectRoot: repo.root)
        }
        #expect(try await repo.branchExists("feature"))
    }

    @Test func cleanUpRemovesWorktreeAndCachesButKeepsUnmergedBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        try repo.write("work.txt", "w\n", in: worktree.path)
        try await repo.commitAll("Work", in: worktree.path)
        let cache = try makeDerivedData(in: repo, named: "App-abc", workspace: worktree.path.appending(path: "App.xcodeproj"))

        let deleted = try await service.cleanUp(worktree, defaultBranch: "main", projectRoot: repo.root, force: false, deleteBranch: true)

        #expect(!deleted)
        #expect(try await repo.branchExists(worktree.branch))
        #expect(!FileManager.default.fileExists(atPath: worktree.path.path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func cleanUpDeletesAMergedBranch() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")

        let deleted = try await service.cleanUp(worktree, defaultBranch: "main", projectRoot: repo.root, force: false, deleteBranch: true)

        #expect(deleted)
        #expect(try await !repo.branchExists(worktree.branch))
    }
}

@Suite struct DiskTests {
    @Test func sizeIncludesDerivedDataInsideAndBuiltFromTheWorktree() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let service = repo.service
        let worktree = try await service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        let baseline = await service.diskSize(of: worktree.path)

        let megabyte = Data(repeating: 7, count: 1 << 20)
        try FileManager.default.createDirectory(at: worktree.path.appending(path: "DerivedData"), withIntermediateDirectories: true)
        try megabyte.write(to: worktree.path.appending(path: "DerivedData/blob"))
        let ours = try makeDerivedData(in: repo, named: "App-ours", workspace: worktree.path.appending(path: "App.xcodeproj"))
        try megabyte.write(to: ours.appending(path: "blob"))
        let theirs = try makeDerivedData(in: repo, named: "App-theirs", workspace: repo.root.appending(path: "App.xcodeproj"))
        try megabyte.write(to: theirs.appending(path: "blob"))

        #expect(service.derivedDataDirectories(for: worktree.path).map(\.lastPathComponent) == ["App-ours"])
        let size = await service.diskSize(of: worktree.path)
        #expect(size - baseline >= 2 << 20)
        #expect(size - baseline < 3 << 20)
    }
}

private func makeDerivedData(in repo: TestRepository, named name: String, workspace: URL) throws -> URL {
    let folder = repo.derivedDataRoot.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace.path], format: .xml, options: 0)
    try plist.write(to: folder.appending(path: "info.plist"))
    return folder
}
