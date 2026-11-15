import Foundation
import Testing
@testable import ConstellationGit

@Suite struct AttachmentStagingTests {
    @Test func copiesOutsideFilesIntoAnExcludedFolder() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let worktree = try await repo.service.createWorktree(projectRoot: repo.root, projectName: "app", base: "main")
        let outside = repo.sandbox.appending(path: "notes.txt")
        try "hello".write(to: outside, atomically: true, encoding: .utf8)
        let id = UUID()

        let staged = try await repo.service.stageAttachment(outside, named: "notes.txt", id: id, in: worktree.path)
        #expect(staged.deletingLastPathComponent() == GitService.canonical(worktree.path).appending(path: ".constellation/attachments", directoryHint: .isDirectory))
        #expect(try String(contentsOf: staged, encoding: .utf8) == "hello")
        // Twice, so the exclude line isn't repeated.
        _ = try await repo.service.stageAttachment(outside, named: "notes.txt", id: id, in: worktree.path)

        let exclude = try String(contentsOf: repo.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.components(separatedBy: "\n").count { $0 == "/.constellation/" } == 1)
        #expect(try await repo.git("status", "--porcelain", in: worktree.path).isEmpty)
    }

    @Test func leavesFilesInsideTheWorktreeWhereTheyAre() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let inside = repo.root.appending(path: "README.md")
        let stored = repo.sandbox.appending(path: "stored-copy.md")
        let staged = try await repo.service.stageAttachment(stored, original: inside, named: "README.md", id: UUID(), in: repo.root)
        #expect(staged == GitService.canonical(inside))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: ".constellation").path(percentEncoded: false)))
    }

    /// If the folder can't be excluded, nothing is copied that could be committed by mistake.
    @Test func copiesNothingWhenTheExcludeCantBeWritten() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        let info = repo.root.appending(path: ".git/info")
        try? FileManager.default.removeItem(at: info)
        try "not a folder".write(to: info, atomically: true, encoding: .utf8)
        let outside = repo.sandbox.appending(path: "notes.txt")
        try "hello".write(to: outside, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await repo.service.stageAttachment(outside, named: "notes.txt", id: UUID(), in: repo.root)
        }
        #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: ".constellation").path(percentEncoded: false)))
    }
}

@Suite struct FileListingTests {
    @Test func listsTrackedAndUntrackedButNotIgnoredFiles() async throws {
        let repo = try await TestRepository(withRemote: false)
        defer { repo.remove() }
        try repo.write(".gitignore", "build/\n")
        try repo.write("Sources/App.swift", "")
        try await repo.commitAll("Add sources")
        try repo.write("notes.md", "")
        try repo.write("build/out.o", "")

        let files = try await repo.service.listFiles(in: repo.root)
        #expect(files.contains("Sources/App.swift"))
        #expect(files.contains("notes.md"))
        #expect(files.contains(".gitignore"))
        #expect(!files.contains("build/out.o"))
        #expect(files == files.sorted())
    }
}
