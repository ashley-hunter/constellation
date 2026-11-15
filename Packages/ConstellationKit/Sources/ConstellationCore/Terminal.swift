import Foundation

/// A plain shell in a project, a worktree or a session's worktree. It has no asks and never recedes.
/// One with a `url` is a browser instead: a web page in the project's pile, loading while `running`.
/// One with a `command` is a task: a shell that runs that command, named for it.
/// One with a `note` is a note: markdown kept in the app's store, with no process at all.
// ponytail: a browser rides on Terminal for piles, focus, closing and the store; split it into its
// own TileItem case if it grows behaviour a shell doesn't share.
public struct Terminal: Identifiable, Hashable, Codable, Sendable {
    public enum State: String, Hashable, Codable, Sendable {
        case running, idle
    }

    public var id: UUID
    public var projectID: UUID
    public var workingDirectory: URL
    public var sessionID: UUID?
    public var title: String
    public var state: State
    public var lastExitCode: Int32?
    public var createdAt: Date
    public var url: URL?
    public var command: String?
    public var note: String?

    /// What a terminal is, from which of `url`, `note` and `command` it has. Only one is ever set;
    /// should more be, a browser wins, then a note, then a task.
    public enum Kind: Hashable, Sendable {
        case shell, task, browser, note
    }

    public var kind: Kind {
        if url != nil { return .browser }
        if note != nil { return .note }
        if command != nil { return .task }
        return .shell
    }

    public var isBrowser: Bool { kind == .browser }
    public var isTask: Bool { kind == .task }
    public var isNote: Bool { kind == .note }

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        workingDirectory: URL,
        sessionID: UUID? = nil,
        title: String,
        state: State = .idle,
        lastExitCode: Int32? = nil,
        createdAt: Date = .now,
        url: URL? = nil,
        command: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.title = title
        self.state = state
        self.lastExitCode = lastExitCode
        self.createdAt = createdAt
        self.url = url
        self.command = command
        self.note = note
    }
}

/// Anything that shows as a tile on the desktop.
public enum TileItem: Hashable, Codable, Sendable {
    case session(UUID)
    case terminal(UUID)
}

/// What you type in a browser's address field, as the page to load: a full URL as it is, localhost,
/// an IP or a bare port over http, anything else with a dot over https, and the rest as a search.
public enum BrowserAddress {
    public static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return URL(string: text) }
        if text.hasPrefix(":"), Int(text.dropFirst()) != nil { return URL(string: "http://localhost\(text)") }
        let host = text.split(separator: "/").first.map { $0.split(separator: ":").first ?? $0 } ?? ""
        let isLocal = host == "localhost" || host.hasSuffix(".localhost") || host.allSatisfy { $0.isNumber || $0 == "." }
        if !text.contains(" "), isLocal || host.contains(".") {
            return URL(string: (isLocal ? "http://" : "https://") + text)
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
}

/// A dev server's address in a shell's or an agent's output, as Vite, Next and the like print it
/// ("Local: http://localhost:5173/"), colour codes and all. The last one wins.
public enum LocalServer {
    public static func url(in text: String) -> URL? {
        let plain = text.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
        let match = plain.matches(of: /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::\d{2,5})?(?:\/[^\s"'<>)\]]*)?/).last
        return match.flatMap { URL(string: String($0.output).replacing("0.0.0.0", with: "localhost")) }
    }
}

/// A note's markdown as its card shows it: the first line as the title and the next few as plain
/// text, with headings, list and quote marks, emphasis and code ticks lightly taken off.
public enum NoteText {
    /// The first line with words in it, without its heading marks; nil for an empty note.
    public static func title(of text: String) -> String? {
        lines(of: text).first.map(plain).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Up to `limit` lines after the title, as plain text.
    public static func preview(of text: String, limit: Int = 6) -> String {
        lines(of: text).dropFirst().prefix(limit).map(plain).joined(separator: "\n")
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func plain(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .replacing(/^(?:#{1,6}\s*|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/, with: "")
            .replacing(/\*\*|__|`/, with: "")
            .replacing(/([*_])(\S.*?)\1/) { String($0.output.2) }
    }
}
