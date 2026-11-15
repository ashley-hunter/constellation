import ConstellationProcess
import Foundation
import os

/// Finds provider binaries on the user's login shell `PATH` and caches the result.
///
/// A GUI app inherits launchd's minimal `PATH`, so the user's own one is read once from an
/// interactive login shell. Children are spawned with that `PATH` too (see `searchPath()`).
public actor BinaryLocator {
    public static let shared = BinaryLocator()

    private var cache: [String: URL] = [:]
    private var resolvedPath: String?
    private let pathProvider: @Sendable () async -> String?

    public init() {
        self.init(pathProvider: { await BinaryLocator.loginShellPATH() })
    }

    init(pathProvider: @escaping @Sendable () async -> String?) {
        self.pathProvider = pathProvider
    }

    public func locate(_ name: String) async throws -> URL {
        if let cached = cache[name] { return cached }
        for directory in await searchPath().split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                cache[name] = candidate
                return candidate
            }
        }
        throw ProviderError.binaryNotFound(name)
    }

    /// The login shell's `PATH` followed by common install locations, without duplicates.
    public func searchPath() async -> String {
        if let resolvedPath { return resolvedPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let fallbacks = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let shellDirectories = (await pathProvider() ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = (shellDirectories + fallbacks).filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        resolvedPath = path
        return path
    }

    public func invalidate() {
        cache.removeAll()
        resolvedPath = nil
    }

    /// Asks the user's login shell for its `PATH`. Interactive, so `.zshrc` additions are included.
    static func loginShellPATH() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__CONSTELLATION_PATH__"
        let process: ChildProcess
        do {
            process = try ChildProcess(
                executable: URL(filePath: shell),
                arguments: ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
                environment: ProcessInfo.processInfo.environment,
                standardError: .null
            )
        } catch {
            return nil
        }

        // Read asynchronously: an rc file may leave a background child holding stdout open.
        let collected = OSAllocatedUnfairLock(initialState: Data())
        process.standardOutput?.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            collected.withLock { $0.append(chunk) }
        }
        func path() -> String? {
            let parts = String(decoding: collected.withLock { $0 }, as: UTF8.self).components(separatedBy: marker)
            return parts.count >= 3 ? parts[1] : nil
        }

        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            process.signal(SIGTERM)
        }
        _ = await process.waitForExit()
        timeout.cancel()

        for _ in 0..<25 where path() == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        process.standardOutput?.readabilityHandler = nil
        return path()
    }
}
