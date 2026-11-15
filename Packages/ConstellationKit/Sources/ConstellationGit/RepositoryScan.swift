import Foundation

/// A git repository found on disk, offered as a project.
public struct SuggestedRepository: Hashable, Sendable, Identifiable {
    public var url: URL
    public var modified: Date

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, modified: Date) {
        self.url = url
        self.modified = modified
    }

    /// Worked in within the last 30 days, so onboarding offers it already ticked.
    public func isRecent(now: Date = .now) -> Bool {
        now.timeIntervalSince(modified) <= 30 * 24 * 60 * 60
    }
}

/// Finds git repositories in the folders people usually keep them in, for onboarding to suggest.
/// Only main checkouts count: a folder whose `.git` is a file is a linked worktree or a submodule.
public enum RepositoryScan {
    /// ~/code, ~/Developer, ~/src, ~/projects and ~/.t3/projects.
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["code", "Developer", "src", "projects", ".t3/projects"].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Repositories up to `depth` folders below each root (the roots themselves don't count),
    /// most recently modified first. Doesn't look inside a repository once it finds one.
    public static func suggestions(in roots: [URL] = defaultRoots, depth: Int = 2, limit: Int = 24) -> [SuggestedRepository] {
        var found: [URL: SuggestedRepository] = [:]
        for root in roots {
            for folder in subfolders(of: root) {
                collect(folder, depth: depth - 1, into: &found)
            }
        }
        return found.values.sorted { ($0.modified, $1.name) > ($1.modified, $0.name) }.prefix(limit).map(\.self)
    }

    /// Whether `folder` is the top of a main checkout.
    public static func isRepository(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func collect(_ folder: URL, depth: Int, into found: inout [URL: SuggestedRepository]) {
        if isRepository(folder) {
            let url = folder.standardizedFileURL.resolvingSymlinksInPath()
            found[url] = SuggestedRepository(url: url, modified: lastActivity(in: folder))
            return
        }
        guard depth > 0 else { return }
        for child in subfolders(of: folder) {
            collect(child, depth: depth - 1, into: &found)
        }
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// The newest of the folder, its `.git` folder and the index, which a commit or checkout touches.
    private static func lastActivity(in folder: URL) -> Date {
        [folder, folder.appending(path: ".git"), folder.appending(path: ".git/index"), folder.appending(path: ".git/HEAD")]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }
}
