import Foundation
import Testing
@testable import ConstellationGit

@Suite struct RepositoryScanTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func repo(_ path: String, modified: Date, worktree: Bool = false) throws {
        let folder = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let git = folder.appending(path: ".git")
        if worktree {
            try Data("gitdir: /elsewhere".utf8).write(to: git)
        } else {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            try Data().write(to: git.appending(path: "index"))
            for url in [git.appending(path: "index"), git, folder] {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
            }
        }
    }

    @Test func findsMainCheckoutsTwoDeepNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date.now
        try repo("ledger", modified: now.addingTimeInterval(-3600))
        try repo("work/atlas", modified: now)
        try repo("work/atlas/vendor/nested", modified: now)
        try repo("a/b/too-deep", modified: now)
        try repo("linked", modified: now, worktree: true)
        try FileManager.default.createDirectory(at: root.appending(path: "plain"), withIntermediateDirectories: true)

        let names = RepositoryScan.suggestions(in: [root, root.appending(path: "missing")]).map(\.name)
        #expect(names == ["atlas", "ledger"])
    }

    @Test func recentMeansWithinThirtyDays() {
        let now = Date.now
        let day: TimeInterval = 24 * 60 * 60
        #expect(SuggestedRepository(url: root, modified: now.addingTimeInterval(-29 * day)).isRecent(now: now))
        #expect(!SuggestedRepository(url: root, modified: now.addingTimeInterval(-31 * day)).isRecent(now: now))
        #expect(!SuggestedRepository(url: root, modified: .distantPast).isRecent(now: now))
    }

    @Test func cloneFolderNameComesFromTheURL() {
        #expect(GitService.repositoryName(fromCloneURL: "https://github.com/owner/atlas.git") == "atlas")
        #expect(GitService.repositoryName(fromCloneURL: "git@github.com:owner/ledger.git ") == "ledger")
        #expect(GitService.repositoryName(fromCloneURL: "https://example.com/owner/plain/") == "plain")
        #expect(GitService.repositoryName(fromCloneURL: "  ") == nil)
    }

    @Test func protectedFoldersAreTheGuardedOnes() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(PrivacyCheck.isProtected(URL(filePath: "/Users/someone/Documents/app"), home: home))
        #expect(PrivacyCheck.isProtected(URL(filePath: "/Users/someone/Desktop"), home: home))
        #expect(PrivacyCheck.isProtected(URL(filePath: "/Volumes/External/repo"), home: home))
        #expect(!PrivacyCheck.isProtected(URL(filePath: "/Users/someone/code/app"), home: home))
        #expect(!PrivacyCheck.isProtected(URL(filePath: "/Users/someone/DocumentsArchive/app"), home: home))
    }
}
