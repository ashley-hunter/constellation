import ConstellationCore
import Foundation
import GRDB

/// SQLite persistence and FTS5 search. Tiles render from the in-memory model; this is for restart and search.
public final class Store: Sendable {
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Constellation")
            .appending(path: "constellation.sqlite")
    }

    let database: DatabaseQueue

    public init(url: URL = Store.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try DatabaseQueue(path: url.path(percentEncoded: false))
        try Schema.migrator.migrate(database)
    }

    private init(database: DatabaseQueue) throws {
        self.database = database
        try Schema.migrator.migrate(database)
    }

    /// An in-memory store for tests and previews.
    public static func inMemory() throws -> Store {
        try Store(database: DatabaseQueue())
    }

    // MARK: Launch

    /// Everything the app needs at launch, after applying the restart rule, with the sessions that
    /// were live and should resume themselves.
    public func restoreAtLaunch() throws -> RestoredState {
        try database.write { db in
            let records = try SessionRecord.filter(Column("lifecycle") != Lifecycle.archived.rawValue).fetchAll(db)
            var stored: [Session] = []
            for record in records {
                let session = try Self.session(from: record, in: db)
                stored.append(session)
                let restarted = Self.applyingRestartRule(to: session)
                if restarted != session { try Self.write(restarted, in: db) }
            }
            var state = try Self.restoredState(in: db)
            state.resumes = RestartResume.plan(for: stored)
            return state
        }
    }

    /// Everything the app needs at launch, as stored.
    public func loadAll() throws -> RestoredState {
        try database.read(Self.restoredState)
    }

    /// Sessions are child processes, so none survive a quit: working and blocked become interrupted,
    /// a launch cut short fails at its stage, and pending asks expire. The app resumes some of the
    /// interrupted ones from there (see `RestartResume`).
    static func applyingRestartRule(to session: Session) -> Session {
        guard session.lifecycle != .archived else { return session }
        var session = session
        switch session.runState {
        case .working, .blocked:
            session.runState = .interrupted
        case .preparing(let stage):
            session.runState = .failed(.launch(stage))
            session.failureMessage = "Constellation quit while this session was launching."
        case .draft, .failed, .done, .interrupted:
            break
        }
        for index in session.asks.indices where session.asks[index].status == .pending {
            session.asks[index].status = .expired
        }
        return session
    }

    private static func restoredState(in db: Database) throws -> RestoredState {
        var positions: [Arrangement: [TileItem: TilePosition]] = [:]
        for record in try LayoutRecord.fetchAll(db) {
            guard let item = record.item else { continue }
            positions[record.arrangement, default: [:]][item] = record.position
        }
        return RestoredState(
            projects: try projects(in: db),
            sessions: try sessions(includingArchived: false, in: db),
            terminals: try terminals(in: db),
            positions: positions,
            pinnedGroups: try groups(in: db).filter(\.isPinned),
            queuedMessages: try queuedMessages(in: db),
            settings: Dictionary(uniqueKeysWithValues: try SettingRecord.fetchAll(db).map { ($0.key, $0.value) })
        )
    }

    // MARK: Projects

    public func projects() throws -> [Project] {
        try database.read(Self.projects)
    }

    public func save(_ project: Project) throws {
        try database.write { try ProjectRecord(project).save($0) }
    }

    /// Every session the project has, archived ones included.
    public func sessionIDs(inProject id: UUID) throws -> [UUID] {
        try database.read { db in
            try SessionRecord.select(Column("id"), as: UUID.self).filter(Column("projectId") == id.uuidString).fetchAll(db)
        }
    }

    /// Deletes the project and, with it, its sessions, their asks and events, and its terminals.
    public func deleteProject(_ id: UUID) throws {
        try database.write { db in
            let owned = Column("projectId") == id.uuidString
            let sessionIDs = try SessionRecord.select(Column("id"), as: UUID.self).filter(owned).fetchAll(db)
            let terminalIDs = try TerminalRecord.select(Column("id"), as: UUID.self).filter(owned).fetchAll(db)
            try Self.forget(sessionIDs.map(TileItem.session) + terminalIDs.map(TileItem.terminal), in: db)
            _ = try ProjectRecord.deleteOne(db, key: id.uuidString)
        }
    }

    private static func projects(in db: Database) throws -> [Project] {
        try ProjectRecord.order(Column.rowID).fetchAll(db).map(\.project)
    }

    // MARK: Sessions

    public func sessions(includingArchived: Bool = false) throws -> [Session] {
        try database.read { try Self.sessions(includingArchived: includingArchived, in: $0) }
    }

    /// Saves the session and replaces its asks. Asks never hold answers, so secret values are never written.
    public func save(_ session: Session) throws {
        try database.write { try Self.write(session, in: $0) }
    }

    private static func write(_ session: Session, in db: Database) throws {
        try SessionRecord(session).save(db)
        try TurnSettingsRecord(session).save(db)
        try AskRecord.filter(Column("sessionId") == session.id.uuidString).deleteAll(db)
        for (position, ask) in session.asks.enumerated() {
            var ask = ask
            ask.sessionID = session.id
            try AskRecord(ask, position: position).insert(db)
        }
    }

    private static func sessions(includingArchived: Bool, in db: Database) throws -> [Session] {
        var request = SessionRecord.order(Column("createdAt"))
        if !includingArchived {
            request = request.filter(Column("lifecycle") != Lifecycle.archived.rawValue)
        }
        let asks = Dictionary(grouping: try AskRecord.order(Column("position")).fetchAll(db), by: \.sessionId)
        let settings = Dictionary(try TurnSettingsRecord.fetchAll(db).map { ($0.sessionId, $0) }) { $1 }
        return try request.fetchAll(db).map { record in
            var session = record.session(asks: asks[record.id, default: []].map(\.ask))
            settings[record.id]?.apply(to: &session)
            return session
        }
    }

    private static func session(from record: SessionRecord, in db: Database) throws -> Session {
        let asks = try AskRecord
            .filter(Column("sessionId") == record.id.uuidString)
            .order(Column("position"))
            .fetchAll(db)
        var session = record.session(asks: asks.map(\.ask))
        try TurnSettingsRecord.fetchOne(db, key: record.id.uuidString)?.apply(to: &session)
        return session
    }

    // MARK: Terminals

    public func terminals() throws -> [Terminal] {
        try database.read(Self.terminals)
    }

    public func save(_ terminal: Terminal) throws {
        try database.write { try TerminalRecord(terminal).save($0) }
    }

    public func deleteTerminal(_ id: UUID) throws {
        try database.write { db in
            try Self.forget([.terminal(id)], in: db)
            _ = try TerminalRecord.deleteOne(db, key: id.uuidString)
        }
    }

    private static func terminals(in db: Database) throws -> [Terminal] {
        try TerminalRecord.order(Column.rowID).fetchAll(db).map(\.terminal)
    }

    // MARK: Events

    /// Appends in one transaction. Callers batch events every 250 ms; see ``EventRecorder``.
    public func append(_ events: [StoredEvent]) throws {
        guard !events.isEmpty else { return }
        try database.write { db in
            for event in events {
                try EventRecord(event).insert(db)
                if let text = event.event.searchableText {
                    try db.execute(
                        sql: "INSERT INTO eventSearch(rowid, text) VALUES (?, ?)",
                        arguments: [db.lastInsertedRowID, text]
                    )
                }
            }
        }
    }

    public func events(for sessionID: UUID) throws -> [StoredEvent] {
        try database.read { db in
            try EventRecord
                .filter(Column("sessionId") == sessionID.uuidString)
                .order(Column("sequence"))
                .fetchAll(db)
                .map(\.stored)
        }
    }

    /// The highest stored sequence for a session, or nil when it has no events yet.
    public func lastSequence(for sessionID: UUID) throws -> Int? {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(sequence) FROM events WHERE sessionId = ?",
                arguments: [sessionID.uuidString]
            )
        }
    }

    // MARK: Layouts

    public func positions(for arrangement: Arrangement) throws -> [TileItem: TilePosition] {
        try database.read { db in
            var positions: [TileItem: TilePosition] = [:]
            for record in try LayoutRecord.filter(Column("arrangement") == arrangement.rawValue).fetchAll(db) {
                if let item = record.item { positions[item] = record.position }
            }
            return positions
        }
    }

    public func savePosition(_ position: TilePosition, of item: TileItem, in arrangement: Arrangement) throws {
        try database.write { try LayoutRecord(arrangement: arrangement, item: item, position: position).save($0) }
    }

    public func resetPositions(for arrangement: Arrangement) throws {
        _ = try database.write { try LayoutRecord.filter(Column("arrangement") == arrangement.rawValue).deleteAll($0) }
    }

    // MARK: Related groups

    public func pinnedGroups() throws -> [RelatedGroup] {
        try database.read { try Self.groups(in: $0).filter(\.isPinned) }
    }

    public func save(_ group: RelatedGroup) throws {
        try database.write { db in
            try GroupRecord(id: group.id, origin: group.origin).save(db)
            try GroupMemberRecord.filter(Column("groupId") == group.id.uuidString).deleteAll(db)
            for member in group.members {
                try GroupMemberRecord(groupID: group.id, item: member).insert(db)
            }
        }
    }

    public func deleteGroup(_ id: UUID) throws {
        _ = try database.write { try GroupRecord.deleteOne($0, key: id.uuidString) }
    }

    private static func groups(in db: Database) throws -> [RelatedGroup] {
        let members = Dictionary(grouping: try GroupMemberRecord.fetchAll(db), by: \.groupId)
        return try GroupRecord.order(Column.rowID).fetchAll(db).map { record in
            RelatedGroup(
                id: record.id,
                origin: record.origin,
                members: Set(members[record.id, default: []].compactMap(\.item))
            )
        }
    }

    /// Removes items' saved positions and group memberships, which have no foreign key to cascade from.
    private static func forget(_ items: [TileItem], in db: Database) throws {
        for item in items {
            let (kind, id) = item.columns
            let arguments: StatementArguments = [kind, id.uuidString]
            try db.execute(sql: "DELETE FROM layouts WHERE itemKind = ? AND itemId = ?", arguments: arguments)
            try db.execute(sql: "DELETE FROM group_members WHERE itemKind = ? AND itemId = ?", arguments: arguments)
        }
    }

    // MARK: Queued messages

    /// Every queued message of non-archived sessions, in each session's send order.
    public func queuedMessages() throws -> [QueuedMessage] {
        try database.read(Self.queuedMessages)
    }

    /// Replaces a session's queue, so edits, reorders and removals are one write.
    public func saveQueue(_ queue: [QueuedMessage], for sessionID: UUID) throws {
        try database.write { db in
            try QueuedMessageRecord.filter(Column("sessionId") == sessionID.uuidString).deleteAll(db)
            for (position, queued) in queue.enumerated() {
                try QueuedMessageRecord(queued, position: position).insert(db)
            }
        }
    }

    private static func queuedMessages(in db: Database) throws -> [QueuedMessage] {
        try QueuedMessageRecord.fetchAll(db, sql: """
            SELECT queued_messages.* FROM queued_messages
            JOIN sessions ON sessions.id = queued_messages.sessionId
            WHERE sessions.lifecycle != ?
            ORDER BY queued_messages.sessionId, queued_messages.position
            """, arguments: [Lifecycle.archived.rawValue]).map(\.queued)
    }

    // MARK: Prompt history

    /// A project's earlier prompts, newest first.
    public func promptHistory(for projectID: UUID, limit: Int = PromptHistory.limit) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT text FROM prompt_history WHERE projectId = ? ORDER BY id DESC LIMIT ?
                """, arguments: [projectID.uuidString, limit])
        }
    }

    /// Records a sent prompt. An earlier copy of the same text is dropped, and each project keeps
    /// the newest `PromptHistory.limit`.
    public func recordPrompt(_ text: String, for projectID: UUID, at date: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try database.write { db in
            let project = projectID.uuidString
            try db.execute(sql: "DELETE FROM prompt_history WHERE projectId = ? AND text = ?", arguments: [project, text])
            try db.execute(
                sql: "INSERT INTO prompt_history (projectId, text, sentAt) VALUES (?, ?, ?)",
                arguments: [project, text, date.timeIntervalSinceReferenceDate]
            )
            try db.execute(sql: """
                DELETE FROM prompt_history WHERE projectId = ? AND id NOT IN (
                    SELECT id FROM prompt_history WHERE projectId = ? ORDER BY id DESC LIMIT ?
                )
                """, arguments: [project, project, PromptHistory.limit])
        }
    }

    // MARK: Palette recents

    /// Keys of rows run from the palette, newest first.
    public func paletteRecents(limit: Int = PaletteRanking.recentsLimit) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM palette_recents ORDER BY usedAt DESC, rowid DESC LIMIT ?", arguments: [limit])
        }
    }

    /// Records a row run from the palette, keeping the newest `PaletteRanking.recentsLimit`.
    public func recordPaletteUse(_ key: String, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM palette_recents WHERE key = ?", arguments: [key])
            try db.execute(sql: "INSERT INTO palette_recents (key, usedAt) VALUES (?, ?)", arguments: [key, date.timeIntervalSinceReferenceDate])
            try db.execute(sql: """
                DELETE FROM palette_recents WHERE key NOT IN (
                    SELECT key FROM palette_recents ORDER BY usedAt DESC, rowid DESC LIMIT ?
                )
                """, arguments: [PaletteRanking.recentsLimit])
        }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try database.read { try SettingRecord.fetchOne($0, key: key)?.value }
    }

    /// Stores a value, or removes the key when the value is nil.
    public func setSetting(_ key: String, to value: String?) throws {
        try database.write { db in
            if let value {
                try SettingRecord(key: key, value: value).save(db)
            } else {
                _ = try SettingRecord.deleteOne(db, key: key)
            }
        }
    }

    // MARK: Search

    /// Full-text search over user and assistant messages and tool summaries, archived sessions included.
    /// Returns the best match per session, best first. Every word in the query matches as a prefix.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0, let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try database.read { db in
            // snippet() can't run under a window function, so pick each session's best event first.
            let rows = try Row.fetchAll(db, sql: """
                SELECT events.sessionId, events.sequence,
                    snippet(eventSearch, 0, ?, ?, '…', 16) AS snippet
                FROM eventSearch JOIN events ON events.id = eventSearch.rowid
                WHERE eventSearch MATCH ? AND eventSearch.rowid IN (
                    SELECT id FROM (
                        SELECT events.id, ROW_NUMBER() OVER (
                            PARTITION BY events.sessionId ORDER BY eventSearch.rank, events.sequence DESC
                        ) AS place
                        FROM eventSearch JOIN events ON events.id = eventSearch.rowid
                        WHERE eventSearch MATCH ?
                    )
                    WHERE place = 1
                )
                ORDER BY eventSearch.rank
                LIMIT ?
                """, arguments: [SearchHit.openMark, SearchHit.closeMark, pattern, pattern, limit])
            return rows.map { row in
                SearchHit(sessionID: row["sessionId"], sequence: row["sequence"], markedSnippet: row["snippet"])
            }
        }
    }
}

/// What the app loads at launch: non-archived sessions, plus everything that lays out the desktop.
public struct RestoredState: Sendable {
    public var projects: [Project]
    public var sessions: [Session]
    public var terminals: [Terminal]
    public var positions: [Arrangement: [TileItem: TilePosition]]
    public var pinnedGroups: [RelatedGroup]
    public var queuedMessages: [QueuedMessage]
    public var settings: [String: String]
    /// Sessions that were live when the app went away and resume themselves, already interrupted
    /// by the restart rule like the rest.
    public var resumes: [RestartResume] = []
}

public struct StoredEvent: Hashable, Sendable {
    public var sessionID: UUID
    public var sequence: Int
    public var time: Date
    public var event: SessionEvent

    public init(sessionID: UUID, sequence: Int, time: Date, event: SessionEvent) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.time = time
        self.event = event
    }
}

public struct SearchHit: Hashable, Sendable {
    public var sessionID: UUID
    public var sequence: Int
    /// The matching text around the hit, with an ellipsis where it was cut.
    public var snippet: String
    /// The matched words within `snippet`.
    public var highlights: [Range<String.Index>]

    public init(sessionID: UUID, sequence: Int, snippet: String, highlights: [Range<String.Index>] = []) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.snippet = snippet
        self.highlights = highlights
    }

    static let openMark = "\u{2}"
    static let closeMark = "\u{3}"

    /// Strips the markers SQLite's snippet() puts around matches, keeping their ranges.
    init(sessionID: UUID, sequence: Int, markedSnippet: String) {
        var snippet = ""
        var highlights: [Range<String.Index>] = []
        var openedAt: String.Index?
        for character in markedSnippet {
            switch String(character) {
            case Self.openMark:
                openedAt = snippet.endIndex
            case Self.closeMark:
                if let start = openedAt { highlights.append(start..<snippet.endIndex) }
                openedAt = nil
            default:
                snippet.append(character)
            }
        }
        self.init(sessionID: sessionID, sequence: sequence, snippet: snippet, highlights: highlights)
    }
}

extension RelatedGroup {
    var isPinned: Bool {
        if case .pinned = origin { true } else { false }
    }
}
