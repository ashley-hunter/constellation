import ConstellationCore
import Foundation

/// Shells out to `git` for projects, worktrees, branches, diffs and clean-up.
public actor GitService {
    public static let defaultWorktreesRoot = URL.homeDirectory.appending(path: ".worktrees")
    public static let defaultDerivedDataRoot = URL.homeDirectory.appending(path: "Library/Developer/Xcode/DerivedData")

    /// Worktrees live at `<worktreesRoot>/<project>/<name>`.
    public private(set) var worktreesRoot: URL
    public let derivedDataRoot: URL
    private let gitExecutable: URL

    public init(
        worktreesRoot: URL = GitService.defaultWorktreesRoot,
        derivedDataRoot: URL = GitService.defaultDerivedDataRoot,
        gitExecutable: URL = URL(filePath: "/usr/bin/git")
    ) {
        self.worktreesRoot = worktreesRoot
        self.derivedDataRoot = derivedDataRoot
        self.gitExecutable = gitExecutable
    }

    /// Where new worktrees go from now on. Existing ones stay where they are.
    public func setWorktreesRoot(_ root: URL) {
        worktreesRoot = root
    }

    // MARK: Projects

    /// `git rev-parse --show-toplevel`. Throws when the folder isn't in a git repo.
    public func repositoryRoot(containing folder: URL) async throws -> URL {
        guard let output = try? await run(["rev-parse", "--show-toplevel"], in: folder), output.status == 0 else {
            throw GitError.notARepository(folder)
        }
        return Self.canonical(URL(filePath: output.stdoutText.trimmed, directoryHint: .isDirectory))
    }

    /// Validates a folder dropped or picked as a new Project.
    public func inspectProject(at folder: URL) async throws -> ProjectRepository {
        let root = try await repositoryRoot(containing: folder)
        return ProjectRepository(root: root, name: root.lastPathComponent, defaultBranch: try await defaultBranch(of: root))
    }

    /// Makes a new folder, runs `git init` in it and makes an empty "Initial commit", so worktrees
    /// have a HEAD to branch from. Throws if the folder already exists, and removes it again if a git step fails. The commit is unsigned, so
    /// creating a project never stops for a signing prompt.
    public func createRepository(at folder: URL) async throws -> ProjectRepository {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try await git(["init", "--quiet"], in: folder)
            try await git(["-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Initial commit"], in: folder)
            return try await inspectProject(at: folder)
        } catch {
            // Nothing but the empty repository we just made is in it, so a retry can start clean.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `git clone <remote> <folder>`, making the folder's parent if needed. Git refuses a folder
    /// that already has something in it, and removes its own half-made clone when it fails.
    public func clone(_ remote: String, into folder: URL) async throws -> ProjectRepository {
        let parent = folder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await git(["clone", "--quiet", "--", remote, folder.path(percentEncoded: false)], in: parent)
        return try await inspectProject(at: folder)
    }

    /// The folder name `git clone` would pick: the URL's last part without `.git`.
    public static func repositoryName(fromCloneURL remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last else { return nil }
        var name = String(last)
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty || name == "." || name == ".." ? nil : name
    }

    /// From `origin/HEAD`, falling back to main or master, then to the current branch.
    public func defaultBranch(of root: URL) async throws -> String {
        let originHead = try await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)
        if originHead.status == 0, case let ref = originHead.stdoutText.trimmed, ref.hasPrefix("origin/") {
            return String(ref.dropFirst("origin/".count))
        }
        for candidate in ["main", "master"] {
            for ref in ["refs/heads/\(candidate)", "refs/remotes/origin/\(candidate)"] where try await refExists(ref, in: root) {
                return candidate
            }
        }
        if let current = try await currentBranch(of: root) {
            return current
        }
        throw GitError.noDefaultBranch(root)
    }

    /// Nil when HEAD is detached.
    public func currentBranch(of directory: URL) async throws -> String? {
        let output = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        return output.status == 0 ? output.stdoutText.trimmed : nil
    }

    /// Local branches a new session can start from, most recently committed first.
    public func localBranches(of root: URL, limit: Int = 30) async throws -> [String] {
        let output = try await git(["for-each-ref", "--sort=-committerdate", "--count=\(limit)", "--format=%(refname:short)", "refs/heads"], in: root)
        return output.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: Launch

    /// Best effort: no prompts, a time limit, and failures ignored.
    public func fetch(_ root: URL) async {
        _ = try? await run(["fetch", "--quiet", "--prune"], in: root, timeout: .seconds(60))
    }

    /// `git worktree add -b constellation/<8hex> <worktreesRoot>/<project>/<8hex> <base>`.
    public func createWorktree(projectRoot: URL, projectName: String, base: String) async throws -> Worktree {
        let projectDirectory = worktreesRoot.appending(path: Self.directoryName(for: projectName), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        for _ in 0..<8 {
            let hex = String(format: "%08x", UInt32.random(in: .min ... .max))
            let branch = BranchSlug.prefix + hex
            let path = projectDirectory.appending(path: hex, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: path.path), try await !refExists("refs/heads/\(branch)", in: projectRoot) else {
                continue
            }
            try await git(["worktree", "add", "--no-track", "-b", branch, "--", path.path, base], in: projectRoot)
            return Worktree(path: Self.canonical(path), branch: branch, baseBranch: base)
        }
        throw GitError.invalidBranchName(BranchSlug.prefix)
    }

    /// Runs the launch stages that touch git: fetch, worktree, setup script.
    /// A failure or cancellation after the worktree exists removes it and its branch again.
    /// The caller starts the provider and calls `discardWorktree` if that fails.
    public func prepareWorktree(
        projectRoot: URL,
        projectName: String,
        base: String,
        setupScript: URL? = nil,
        onProgress: @escaping @Sendable (WorktreeLaunchProgress) -> Void = { _ in }
    ) async throws -> Worktree {
        onProgress(.stage(.fetch))
        await fetch(projectRoot)

        onProgress(.stage(.worktree))
        let worktree: Worktree
        do {
            try Task.checkCancellation()
            worktree = try await createWorktree(projectRoot: projectRoot, projectName: projectName, base: base)
        } catch {
            throw WorktreeLaunchError(stage: .worktree, underlying: error)
        }

        guard let script = Self.setupScript(explicit: setupScript, worktree: worktree.path, projectRoot: projectRoot) else {
            return worktree
        }
        onProgress(.stage(.setup))
        do {
            try Task.checkCancellation()
            try await runSetupScript(script, worktree: worktree.path, projectRoot: projectRoot) {
                onProgress(.setupOutput($0))
            }
            try Task.checkCancellation()
        } catch {
            // A fresh task, so the rollback still runs when this one was cancelled.
            await Task { try? await self.discardWorktree(worktree, projectRoot: projectRoot) }.value
            throw WorktreeLaunchError(stage: .setup, underlying: error)
        }
        return worktree
    }

    /// Runs the script in the worktree through a login shell, so it sees the user's PATH, with
    /// `environment` (the worktree's port) added.
    /// Returns stdout and stderr interleaved; throws `setupScriptFailed` on a non-zero exit.
    @discardableResult
    public func runSetupScript(
        _ script: URL,
        worktree: URL,
        projectRoot: URL,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let launcher = #"if [ -x "$1" ]; then exec "$1"; else exec /bin/sh "$1"; fi"#
        let output = try await ProcessRunner.run(
            URL(filePath: "/bin/zsh"),
            ["-lc", launcher, "constellation-setup", script.path],
            in: worktree,
            environment: environment.merging([
                "CONSTELLATION_WORKTREE": worktree.path,
                "CONSTELLATION_PROJECT_ROOT": projectRoot.path,
            ]) { $1 },
            mergeOutput: true,
            onOutput: { onOutput(String(decoding: $0, as: UTF8.self)) }
        )
        guard output.status == 0 else {
            throw GitError.setupScriptFailed(status: output.status, output: output.stdoutText)
        }
        return output.stdoutText
    }

    /// The configured script, else `.constellation/setup.sh` in the worktree, else in the project root.
    static func setupScript(explicit: URL?, worktree: URL, projectRoot: URL) -> URL? {
        if let explicit { return explicit }
        return [worktree, projectRoot]
            .map { $0.appending(path: Project.defaultSetupScript) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Rollback for a launch that never got going: force-removes the worktree and its branch.
    public func discardWorktree(_ worktree: Worktree, projectRoot: URL) async throws {
        try await removeWorktree(worktree.path, projectRoot: projectRoot, force: true)
        guard worktree.branch.hasPrefix(BranchSlug.prefix) else { throw GitError.refusedToDeleteBranch(worktree.branch) }
        if try await refExists("refs/heads/\(worktree.branch)", in: projectRoot) {
            try await git(["branch", "-D", "--", worktree.branch], in: projectRoot)
        }
    }

    // MARK: Rename

    /// Renames the branch to `constellation/<slug>`, and moves the worktree to `<worktreesRoot>/<project>/<slug>`
    /// unless `moveDirectory` is false (the provider has already started there). A suffix avoids collisions.
    /// A move git refuses (locked, submodules) leaves the worktree where it was.
    public func rename(_ worktree: Worktree, projectRoot: URL, to slug: String, moveDirectory: Bool) async throws -> Worktree {
        guard worktree.branch.hasPrefix(BranchSlug.prefix) else { throw GitError.invalidBranchName(worktree.branch) }
        let check = try await run(["check-ref-format", "--branch", BranchSlug.prefix + slug], in: projectRoot)
        guard !slug.isEmpty, !slug.hasPrefix("-"), check.status == 0 else { throw GitError.invalidBranchName(slug) }

        var renamed = worktree
        var suffix = 1
        var branch = BranchSlug.prefix + slug
        while branch != worktree.branch, try await refExists("refs/heads/\(branch)", in: projectRoot) {
            suffix += 1
            branch = BranchSlug.prefix + "\(slug)-\(suffix)"
        }
        if branch != worktree.branch {
            try await git(["branch", "-m", worktree.branch, branch], in: projectRoot)
            renamed.branch = branch
        }

        guard moveDirectory else { return renamed }
        let parent = worktree.path.deletingLastPathComponent()
        var destination = parent.appending(path: slug, directoryHint: .isDirectory)
        suffix = 1
        while Self.canonical(destination) != Self.canonical(worktree.path), FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = parent.appending(path: "\(slug)-\(suffix)", directoryHint: .isDirectory)
        }
        guard Self.canonical(destination) != Self.canonical(worktree.path) else { return renamed }
        if let moved = try? await run(["worktree", "move", "--", worktree.path.path, destination.path], in: projectRoot), moved.status == 0 {
            renamed.path = Self.canonical(destination)
        }
        return renamed
    }

    // MARK: Status

    public func status(of worktree: URL, defaultBranch: String) async throws -> WorktreeStatus {
        let output = try await git(["status", "--porcelain=v2", "--branch", "-z"], in: worktree)
        var status = Self.parseStatus(output.stdoutText)
        status.isMerged = try await isMerged("HEAD", into: defaultBranch, in: worktree)
        status.isPushed = try await isPushed("HEAD", in: worktree)
        return status
    }

    public func isMerged(_ branch: String, into defaultBranch: String, projectRoot: URL) async throws -> Bool {
        try await isMerged("refs/heads/\(branch)", into: defaultBranch, in: projectRoot)
    }

    public func isPushed(_ branch: String, projectRoot: URL) async throws -> Bool {
        try await isPushed("refs/heads/\(branch)", in: projectRoot)
    }

    /// Reachable from the default branch, locally or on origin. Squash merges need the PR state instead.
    private func isMerged(_ revision: String, into defaultBranch: String, in directory: URL) async throws -> Bool {
        for target in ["refs/heads/\(defaultBranch)", "refs/remotes/origin/\(defaultBranch)"] {
            guard try await refExists(target, in: directory) else { continue }
            let check = try await run(["merge-base", "--is-ancestor", revision, target], in: directory)
            switch check.status {
            case 0: return true
            case 1: continue
            default: throw GitError.commandFailed(arguments: ["merge-base", revision, target], status: check.status, stderr: check.stderrText)
            }
        }
        return false
    }

    /// Every commit is on some remote-tracking branch.
    private func isPushed(_ revision: String, in directory: URL) async throws -> Bool {
        let output = try await git(["for-each-ref", "--count=1", "--contains", revision, "--format=%(refname)", "refs/remotes"], in: directory)
        return !output.stdoutText.trimmed.isEmpty
    }

    static func parseStatus(_ porcelain: String) -> WorktreeStatus {
        var status = WorktreeStatus(branch: nil, dirtyFileCount: 0, ahead: 0, behind: 0, hasUpstream: false, isMerged: false, isPushed: false)
        var records = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            if record.hasPrefix("# branch.head ") {
                let head = String(record.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if record.hasPrefix("# branch.upstream ") {
                status.hasUpstream = true
            } else if record.hasPrefix("# branch.ab ") {
                let counts = record.split(separator: " ").suffix(2).compactMap { Int($0.dropFirst()) }
                if counts.count == 2 { (status.ahead, status.behind) = (counts[0], counts[1]) }
            } else if !record.hasPrefix("#") {
                status.dirtyFileCount += 1
                // A rename or copy record is followed by its original path.
                if record.hasPrefix("2 ") { _ = records.next() }
            }
        }
        return status
    }

    // MARK: Diffs

    /// Files changed since the merge base with `base`: committed, staged, unstaged and untracked.
    public func changedFiles(in worktree: URL, against base: String) async throws -> [String] {
        let mergeBase = try await mergeBase(base, in: worktree)
        let tracked = try await git(["diff", "--name-only", "--no-renames", "-z", mergeBase], in: worktree)
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
        let files = (tracked.stdoutText + untracked.stdoutText).split(separator: "\0").map(String.init)
        return Set(files).sorted()
    }

    /// Every file in the worktree that isn't ignored: tracked plus untracked, relative and sorted.
    public func listFiles(in worktree: URL) async throws -> [String] {
        let output = try await git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: worktree)
        return Set(output.stdoutText.split(separator: "\0").map(String.init)).sorted()
    }

    public func unifiedDiff(in worktree: URL, against base: String) async throws -> String {
        let mergeBase = try await mergeBase(base, in: worktree)
        return try await git(["diff", "--no-color", "--no-ext-diff", mergeBase], in: worktree).stdoutText
    }

    func mergeBase(_ base: String, in worktree: URL) async throws -> String {
        try await git(["merge-base", base, "HEAD"], in: worktree).stdoutText.trimmed
    }

    // MARK: Clean-up

    /// `git worktree remove`. Refuses a project root, the main worktree, and anything git doesn't list
    /// as a linked worktree of this project. A worktree already deleted from disk is pruned instead.
    public func removeWorktree(_ path: URL, projectRoot: URL, force: Bool) async throws {
        let target = Self.canonical(path)
        guard target != Self.canonical(projectRoot) else { throw GitError.refusedToRemove(path) }

        let worktrees = try await worktreePaths(of: projectRoot)
        guard target != worktrees.first else { throw GitError.refusedToRemove(path) }
        guard FileManager.default.fileExists(atPath: target.path) else {
            try await git(["worktree", "prune"], in: projectRoot)
            return
        }
        guard worktrees.dropFirst().contains(target) else { throw GitError.refusedToRemove(path) }

        try await git(["worktree", "remove"] + (force ? ["--force"] : []) + ["--", target.path], in: projectRoot)
    }

    /// `git branch -D`, only for a Constellation branch that is merged into the default branch or pushed.
    public func deleteBranch(_ branch: String, defaultBranch: String, projectRoot: URL) async throws {
        guard branch.hasPrefix(BranchSlug.prefix), branch != defaultBranch else { throw GitError.refusedToDeleteBranch(branch) }
        guard try await refExists("refs/heads/\(branch)", in: projectRoot) else { return }
        let merged = try await isMerged(branch, into: defaultBranch, projectRoot: projectRoot)
        let pushed = try await isPushed(branch, projectRoot: projectRoot)
        guard merged || pushed else { throw GitError.refusedToDeleteBranch(branch) }
        try await git(["branch", "-D", "--", branch], in: projectRoot)
    }

    /// Clean-up for one archived session: the worktree, then the branch when safe and wanted, then its caches.
    /// Returns whether the branch was deleted; an unsafe branch is kept rather than treated as an error.
    @discardableResult
    public func cleanUp(_ worktree: Worktree, defaultBranch: String, projectRoot: URL, force: Bool, deleteBranch: Bool) async throws -> Bool {
        try await removeWorktree(worktree.path, projectRoot: projectRoot, force: force)
        var deleted = false
        if deleteBranch {
            do {
                try await self.deleteBranch(worktree.branch, defaultBranch: defaultBranch, projectRoot: projectRoot)
                deleted = true
            } catch GitError.refusedToDeleteBranch {}
        }
        try removeCaches(for: worktree.path)
        return deleted
    }

    private func worktreePaths(of projectRoot: URL) async throws -> [URL] {
        let output = try await git(["worktree", "list", "--porcelain", "-z"], in: projectRoot)
        return output.stdoutText.split(separator: "\0")
            .filter { $0.hasPrefix("worktree ") }
            .map { Self.canonical(URL(filePath: String($0.dropFirst("worktree ".count)), directoryHint: .isDirectory)) }
    }

    // MARK: Disk

    /// The worktree, including any DerivedData inside it, plus Xcode DerivedData folders built from it.
    @concurrent
    public nonisolated func diskSize(of worktree: URL) async -> Int64 {
        ([worktree] + derivedDataDirectories(for: worktree)).reduce(0) { $0 + Self.allocatedSize(of: $1) }
    }

    /// Folders in `derivedDataRoot` whose `info.plist` names a workspace inside the worktree.
    public nonisolated func derivedDataDirectories(for worktree: URL) -> [URL] {
        let prefixes = Set([worktree.standardizedFileURL.path, Self.canonical(worktree).path, worktree.resolvingSymlinksInPath().path])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let folders = (try? FileManager.default.contentsOfDirectory(at: derivedDataRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = plist["WorkspacePath"] as? String
            else { return false }
            return prefixes.contains { workspace.hasPrefix($0) }
        }
    }

    /// Deletes the Xcode DerivedData folders built from the worktree. Works after the worktree is gone.
    public nonisolated func removeCaches(for worktree: URL) throws {
        for folder in derivedDataDirectories(for: worktree) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Attachments

    /// Where an attached file is readable from inside `worktree`. An `original` already inside it
    /// stays put; otherwise `file`, Constellation's checked copy, is copied into
    /// `.constellation/attachments/`. That folder is excluded locally first, so it never shows as
    /// untracked, joins a checkpoint or stops a clean-up, and nothing is copied if that fails.
    public func stageAttachment(_ file: URL, original: URL? = nil, named name: String, id: UUID, in worktree: URL) async throws -> URL {
        let root = Self.canonical(worktree)
        let rootPath = root.path(percentEncoded: false)
        if let original = original.map(Self.canonical),
           original.path(percentEncoded: false).hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
           FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) {
            return original
        }

        try await excludeLocally("/.constellation/", in: root)
        let folder = root.appending(path: Self.attachmentsFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "\(id.uuidString.prefix(8))-\(name)")
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: file, to: destination)
        }
        return destination
    }

    static let attachmentsFolder = ".constellation/attachments"

    /// Adds a pattern to the repository's `info/exclude` unless it is there already. Worktrees share
    /// the main repository's file, which `--git-path` finds.
    func excludeLocally(_ pattern: String, in worktree: URL) async throws {
        let path = try await git(["rev-parse", "--git-path", "info/exclude"], in: worktree).stdoutText.trimmed
        let exclude = path.hasPrefix("/") ? URL(filePath: path) : worktree.appending(path: path)
        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !existing.split(whereSeparator: \.isNewline).contains(where: { $0 == pattern }) else { return }
        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + pattern + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    // MARK: Plumbing

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func directoryName(for projectName: String) -> String {
        let cleaned = projectName
            .replacing(/[\/:]/, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return cleaned.isEmpty ? "project" : cleaned
    }

    func refExists(_ ref: String, in directory: URL) async throws -> Bool {
        try await run(["show-ref", "--verify", "--quiet", ref], in: directory).status == 0
    }

    /// Runs git and throws `commandFailed` on a non-zero exit.
    @discardableResult
    func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> ProcessOutput {
        let output = try await run(arguments, in: directory, environment: environment)
        guard output.status == 0 else {
            throw GitError.commandFailed(arguments: arguments, status: output.status, stderr: output.stderrText.trimmed)
        }
        return output
    }

    func run(_ arguments: [String], in directory: URL, environment: [String: String] = [:], timeout: Duration? = nil) async throws -> ProcessOutput {
        try await ProcessRunner.run(
            gitExecutable,
            arguments,
            in: directory,
            environment: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_SSH_COMMAND": ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes",
            ].merging(environment) { $1 },
            timeout: timeout
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
