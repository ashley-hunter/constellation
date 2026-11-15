import ConstellationCore
import Foundation

public struct Worktree: Hashable, Codable, Sendable {
    public var path: URL
    public var branch: String
    public var baseBranch: String

    public init(path: URL, branch: String, baseBranch: String) {
        self.path = path
        self.branch = branch
        self.baseBranch = baseBranch
    }
}

/// A repository accepted as a Project.
public struct ProjectRepository: Hashable, Sendable {
    public var root: URL
    public var name: String
    public var defaultBranch: String

    public init(root: URL, name: String, defaultBranch: String) {
        self.root = root
        self.name = name
        self.defaultBranch = defaultBranch
    }
}

public struct WorktreeStatus: Hashable, Sendable {
    /// Nil when HEAD is detached.
    public var branch: String?
    public var dirtyFileCount: Int
    public var ahead: Int
    public var behind: Int
    public var hasUpstream: Bool
    /// HEAD is reachable from the default branch, locally or on origin.
    public var isMerged: Bool
    /// HEAD is reachable from some remote-tracking branch.
    public var isPushed: Bool

    public init(
        branch: String?,
        dirtyFileCount: Int,
        ahead: Int,
        behind: Int,
        hasUpstream: Bool,
        isMerged: Bool,
        isPushed: Bool
    ) {
        self.branch = branch
        self.dirtyFileCount = dirtyFileCount
        self.ahead = ahead
        self.behind = behind
        self.hasUpstream = hasUpstream
        self.isMerged = isMerged
        self.isPushed = isPushed
    }
}

extension WorktreeFacts {
    public init(status: WorktreeStatus, sizeInBytes: Int64) {
        self.init(
            hasUncommittedChanges: status.dirtyFileCount > 0,
            hasUnpushedCommits: !status.isPushed && !status.isMerged,
            isMerged: status.isMerged,
            sizeInBytes: sizeInBytes
        )
    }
}

/// Progress from `GitService.prepareWorktree`, in launch order.
public enum WorktreeLaunchProgress: Sendable {
    case stage(LaunchStage)
    case setupOutput(String)
}

public struct WorktreeLaunchError: Error {
    public var stage: LaunchStage
    public var underlying: any Error
}

public enum GitError: Error, Hashable, Sendable {
    case notARepository(URL)
    case noDefaultBranch(URL)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case invalidBranchName(String)
    case setupScriptFailed(status: Int32, output: String)
    /// The path is a project root, the main worktree, or not a worktree of this project.
    case refusedToRemove(URL)
    /// The branch is neither merged into the default branch nor pushed, or isn't a Constellation branch.
    case refusedToDeleteBranch(String)
}
