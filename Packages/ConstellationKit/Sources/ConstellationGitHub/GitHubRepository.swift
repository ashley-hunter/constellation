import Foundation

public struct GitHubRepository: Hashable, Codable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Parses an `origin` URL, returning nil for remotes that aren't on github.com.
    ///
    /// Accepts scp-style ssh (`git@github.com:o/r.git`) and URL forms over https, ssh and git,
    /// including `ssh.github.com:443` and credentials in the authority.
    public init?(remoteURL: String) {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let host = url.host()?.lowercased(),
                  host == "github.com" || host == "www.github.com" || host == "ssh.github.com"
            else { return nil }
            path = Substring(url.path())
        } else {
            // scp-like syntax: [user@]github.com:owner/repo
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let host = trimmed[..<colon].split(separator: "@").last.map { $0.lowercased() }
            guard host == "github.com" else { return nil }
            path = trimmed[trimmed.index(after: colon)...]
        }

        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        self.init(owner: String(parts[0]), name: name)
    }

    /// The GitHub repository behind a local checkout: `origin` if it is on GitHub, otherwise the first GitHub remote.
    /// Nil when git is missing, the directory is not a repo, or no remote is on GitHub.
    public static func resolve(repositoryAt directory: URL) async -> GitHubRepository? {
        guard let git = Subprocess.locate("git"),
              let output = try? await Subprocess.run(git, ["remote", "-v"], in: directory)
        else { return nil }
        return fromRemoteList(output)
    }

    /// Picks a repository from `git remote -v` output.
    static func fromRemoteList(_ output: String) -> GitHubRepository? {
        let remotes = output.split(whereSeparator: \.isNewline).compactMap { line -> (String, GitHubRepository)? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let repository = GitHubRepository(remoteURL: String(fields[1])) else { return nil }
            return (String(fields[0]), repository)
        }
        return remotes.first { $0.0 == "origin" }?.1 ?? remotes.first?.1
    }
}
