import ConstellationCore
import ConstellationStore
import SwiftUI

/// A session found by ⌘K, with the matching text when the hit came from its transcript.
struct SearchResult: Identifiable {
    let session: Session
    let snippet: AttributedString?

    var id: UUID { session.id }
    var isArchived: Bool { session.lifecycle == .archived }
}

/// Searches every session, archived ones included: titles first, then transcript hits from the store's FTS.
struct SessionSearch: Sendable {
    let store: Store

    /// Every stored session, so hits in archived ones have a title and project.
    func allSessions() async -> [UUID: Session] {
        let store = store
        let sessions = await Task.detached { (try? store.sessions(includingArchived: true)) ?? [] }.value
        return Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    func results(for query: String, in sessions: [UUID: Session], limit: Int = 40) async -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sessions.values.sorted { $0.lastActivityAt > $1.lastActivityAt }.prefix(8).map { SearchResult(session: $0, snippet: nil) }
        }
        let store = store
        let hits = await Task.detached { (try? store.search(query, limit: limit)) ?? [] }.value
        let snippets = Dictionary(hits.map { ($0.sessionID, Self.attributed($0)) }, uniquingKeysWith: { first, _ in first })
        let byTitle = sessions.values
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let titled = Set(byTitle.map(\.id))
        let byText = hits.compactMap { hit in titled.contains(hit.sessionID) ? nil : sessions[hit.sessionID] }
        return (byTitle + byText).prefix(limit).map { SearchResult(session: $0, snippet: snippets[$0.id]) }
    }

    private static func attributed(_ hit: SearchHit) -> AttributedString {
        var text = AttributedString()
        var cursor = hit.snippet.startIndex
        for range in hit.highlights.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound >= cursor {
            text += AttributedString(String(hit.snippet[cursor..<range.lowerBound]))
            var match = AttributedString(String(hit.snippet[range]))
            match.foregroundColor = Palette.text
            match.backgroundColor = Palette.ask.opacity(0.22)
            text += match
            cursor = range.upperBound
        }
        text += AttributedString(String(hit.snippet[cursor...]))
        return text
    }
}
