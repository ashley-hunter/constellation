import Foundation

/// What is typed in the ⌘K palette: `>` keeps commands, `@` sessions and projects, and `/` the
/// focused session's slash commands. Anything else searches everything.
public struct PaletteQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case everything, commands, sessions, slashCommands
    }

    public var scope: Scope
    /// The query without its prefix, trimmed.
    public var text: String

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let scope: Scope? = switch trimmed.first {
        case ">": .commands
        case "@": .sessions
        case "/": .slashCommands
        default: nil
        }
        self.scope = scope ?? .everything
        text = (scope == nil ? trimmed : String(trimmed.dropFirst())).trimmingCharacters(in: .whitespaces)
    }

    /// Transcript matches join in from three characters, as full-text search gets noisy below that.
    public var searchesTranscripts: Bool {
        (scope == .everything || scope == .sessions) && text.count >= PaletteRanking.transcriptMinimum
    }
}

/// Fuzzy ranking for palette rows: the title or any keyword can match, and recently used rows
/// come first among the matches, newest first.
public enum PaletteRanking {
    public static let transcriptMinimum = 3
    /// How many recently used rows the store keeps.
    public static let recentsLimit = 50
    /// A keyword match ranks a little below the same match in the title.
    static let keywordPenalty = 4

    /// Nil when neither the title nor a keyword matches. An empty query matches everything.
    public static func score(_ query: String, title: String, keywords: [String] = []) -> Int? {
        guard !query.isEmpty else { return 0 }
        let titleScore = FuzzyMatch.score(query, in: title)
        let keywordScore = keywords.compactMap { FuzzyMatch.score(query, in: $0) }.max().map { $0 - keywordPenalty }
        return [titleScore, keywordScore].compactMap(\.self).max()
    }

    /// The matching candidates: recent ones first, newest first, then by score, then in the order given.
    /// `recents` holds keys newest first.
    public static func rank<T>(
        _ query: String,
        _ candidates: [T],
        recents: [String] = [],
        key: (T) -> String,
        title: (T) -> String,
        keywords: (T) -> [String] = { _ in [] }
    ) -> [T] {
        let recency = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.enumerated()
            .compactMap { index, candidate -> (T, Int, Int, Int)? in
                guard let score = score(query, title: title(candidate), keywords: keywords(candidate)) else { return nil }
                return (candidate, recency[key(candidate)] ?? .max, score, index)
            }
            .sorted { ($0.1, -$0.2, $0.3) < ($1.1, -$1.2, $1.3) }
            .map(\.0)
    }

    /// `recents` (newest first) after using `key`: it moves to the front, appearing once.
    public static func recording(_ key: String, in recents: [String]) -> [String] {
        Array(([key] + recents.filter { $0 != key }).prefix(recentsLimit))
    }
}
