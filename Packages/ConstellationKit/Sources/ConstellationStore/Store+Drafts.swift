import ConstellationCore
import Foundation
import GRDB

/// Draft sessions: the session row plus the first message being written. An empty draft is never
/// stored, so these are only written once there is something to keep.
extension Store {
    /// Saves a draft session and its unsent first message together.
    public func saveDraft(_ session: Session, message: UserMessage) throws {
        try database.write { db in
            try SessionRecord(session).save(db)
            try TurnSettingsRecord(session).save(db)
            try SessionDraftRecord(sessionId: session.id, message: message).save(db)
        }
    }

    /// Each stored draft's unsent first message, by session id.
    public func draftMessages() throws -> [UUID: UserMessage] {
        try database.read { db in
            Dictionary(try SessionDraftRecord.fetchAll(db).map { ($0.sessionId, $0.message) }) { first, _ in first }
        }
    }

    /// Removes a session that never launched, with its layout position and group memberships.
    public func deleteSession(_ id: UUID) throws {
        try database.write { db in
            let (kind, id) = TileItem.session(id).columns
            let arguments: StatementArguments = [kind, id.uuidString]
            try db.execute(sql: "DELETE FROM layouts WHERE itemKind = ? AND itemId = ?", arguments: arguments)
            try db.execute(sql: "DELETE FROM group_members WHERE itemKind = ? AND itemId = ?", arguments: arguments)
            _ = try SessionRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Forgets the unsent message once the draft has launched.
    public func clearDraftMessage(for id: UUID) throws {
        try database.write { db in
            _ = try SessionDraftRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

struct SessionDraftRecord: StoreRecord {
    static let databaseTableName = "session_drafts"

    var sessionId: UUID
    var message: UserMessage
}
