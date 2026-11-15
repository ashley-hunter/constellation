import Foundation
import Testing
@testable import ConstellationGit

@Suite struct CheckpointTests {
    @Test func snapshotLeavesTheWorktreeAloneAndKeepsAHiddenRef() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("tracked.txt", "edited\n")
        try repo.write("new.txt", "untracked\n")
        let session = UUID()
        let statusBefore = try await repo.git("status", "--porcelain")

        let commit = try await repo.service.snapshot(repo.root, session: session)

        #expect(try await repo.git("status", "--porcelain") == statusBefore)
        #expect(try await repo.git("rev-parse", "refs/constellation/\(session.uuidString.lowercased())/\(commit)").trimmingCharacters(in: .whitespacesAndNewlines) == commit)
        #expect(try await repo.git("show", "\(commit):new.txt") == "untracked")
        #expect(try await repo.git("show", "\(commit):tracked.txt") == "edited")

        try repo.write("new.txt", "changed\n")
        _ = try await repo.service.snapshot(repo.root, session: session)
        #expect(try await repo.git("for-each-ref", "--format=%(objectname)", "refs/constellation/").split(separator: "\n").count == 2)
        await repo.service.deleteCheckpoints(session: session, in: repo.root)
        #expect(try await repo.git("for-each-ref", "refs/constellation/").isEmpty)
    }

    /// Snapshots taken at the same time each keep their own ref, so neither can be collected.
    @Test func concurrentSnapshotsKeepEveryCommit() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let session = UUID()
        let service = repo.service
        let root = repo.root
        let commits = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<4 {
                try repo.write("file-\(index).txt", "\(index)\n")
                group.addTask { try await service.snapshot(root, session: session) }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        let kept = Set(try await repo.git("for-each-ref", "--format=%(objectname)", "refs/constellation/").split(separator: "\n").map(String.init))
        #expect(commits.isSubset(of: kept))
    }

    @Test func restorePutsFilesAndTheBranchBack() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("tracked.txt", "before\n")
        try repo.write("kept.txt", "untracked before\n")
        try repo.write(".gitignore", "build/\n")
        try await repo.commitAll("base")
        try repo.write("kept.txt", "untracked before\n")
        let head = try await repo.git("rev-parse", "HEAD")
        let checkpoint = try await repo.service.snapshot(repo.root, session: UUID())

        // The agent's turn: edits, a new file, a deletion, a commit and some build output.
        try repo.write("tracked.txt", "after\n")
        try repo.write("added.txt", "new\n")
        try await repo.commitAll("agent work")
        try FileManager.default.removeItem(at: repo.root.appending(path: "kept.txt"))
        try repo.write("build/out.o", "ignored\n")

        let loss = try await repo.service.loss(restoring: checkpoint, in: repo.root)
        #expect(Set(loss.files) == ["tracked.txt", "added.txt", "kept.txt"])
        #expect(loss.commits == 1)

        try await repo.service.restore(checkpoint, in: repo.root)

        #expect(try await repo.git("rev-parse", "HEAD") == head)
        #expect(try String(contentsOf: repo.root.appending(path: "tracked.txt"), encoding: .utf8) == "before\n")
        #expect(try String(contentsOf: repo.root.appending(path: "kept.txt"), encoding: .utf8) == "untracked before\n")
        #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: "added.txt").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: repo.root.appending(path: "build/out.o").path(percentEncoded: false)))
        #expect(try await repo.service.loss(restoring: checkpoint, in: repo.root).isEmpty)
        #expect(try await repo.git("diff", "--cached", "--name-only").isEmpty)
    }
}
