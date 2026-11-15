import Foundation

/// Whether child processes can read your projects. git, the shells and setup scripts run as
/// Constellation's children, and macOS silently refuses them (EPERM) in privacy-protected folders
/// the app has no grant for. Full Disk Access is the one grant that covers every such folder.
public enum PrivacyCheck {
    /// Folders macOS guards per app: Desktop, Documents, Downloads, iCloud Drive and other volumes.
    public static func isProtected(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func trimmed(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let (path, homePath) = (trimmed(folder), trimmed(home))
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(homePath)/\($0)" } + ["/Volumes"]
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The folders in protected places that a child process can't list.
    public static func blockedFolders(_ folders: [URL]) async -> [URL] {
        var blocked: [URL] = []
        for folder in folders where isProtected(folder) {
            let output = try? await ProcessRunner.run(URL(filePath: "/bin/ls"), ["-A", folder.path(percentEncoded: false)], timeout: .seconds(5))
            if let output, output.status != 0, output.stderrText.contains("Operation not permitted") {
                blocked.append(folder)
            }
        }
        return blocked
    }
}
