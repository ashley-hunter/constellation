import Foundation

/// Picking the session for the split screen's next tile, Snap Assist style: the empty slot shows
/// the other sessions to choose from.
public enum GridPick {
    /// The sessions that could fill the next tile: those that need you first, in triage's order,
    /// then the rest, latest first. Archived sessions, drafts and those in `excluding` are left
    /// out. With a query, only those whose title or project name hold every word of it.
    public static func candidates(
        _ sessions: some Sequence<Session>,
        excluding: Set<UUID>,
        query: String = "",
        projectName: (Session) -> String? = { _ in nil }
    ) -> [Session] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let open = sessions.filter { session in
            guard session.lifecycle != .archived, !session.isDraft, !excluding.contains(session.id) else { return false }
            let text = session.title + " " + (projectName(session) ?? "")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        let needsYou = Triage.queue(open)
        let rank = Dictionary(uniqueKeysWithValues: needsYou.enumerated().map { ($1, $0) })
        return open.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return a.lastActivityAt != b.lastActivityAt ? a.lastActivityAt > b.lastActivityAt : a.id.uuidString < b.id.uuidString
            }
        }
    }

    /// Where `count` tiles sit while one more is picked, and the empty slot it will land in: the
    /// layout of `count + 1`, the slot last. Nil once the grid is full.
    public static func frames(count: Int, in bounds: CGRect, gap: Double) -> (tiles: [CGRect], slot: CGRect)? {
        guard count < SessionGrid.capacity else { return nil }
        var frames = SessionGrid.frames(count: count + 1, in: bounds, gap: gap)
        let slot = frames.removeLast()
        return (frames, slot)
    }
}
