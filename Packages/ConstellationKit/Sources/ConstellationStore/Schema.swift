import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2-queue", migrate: v2Queue)
        migrator.registerMigration("v2-turn-settings", migrate: v2TurnSettings)
        migrator.registerMigration("v2-prompt-history", migrate: v2PromptHistory)
        migrator.registerMigration("v2-usage", migrate: v2Usage)
        migrator.registerMigration("v3-palette-recents", migrate: v3PaletteRecents)
        migrator.registerMigration("v4-session-drafts", migrate: v4SessionDrafts)
        migrator.registerMigration("v5-browsers", migrate: v5Browsers)
        migrator.registerMigration("v6-tasks", migrate: v6Tasks)
        migrator.registerMigration("v7-notes", migrate: v7Notes)
        migrator.registerMigration("v8-no-plan-mode", migrate: v8NoPlanMode)
        return migrator
    }

    /// Plan mode is gone: its setting goes, and so do plan asks and the events that raised them,
    /// which no longer decode.
    private static func v8NoPlanMode(_ db: Database) throws {
        try db.alter(table: "session_turn_settings") { t in t.drop(column: "planMode") }
        try db.execute(sql: "DELETE FROM asks WHERE json_extract(kind, '$.plan') IS NOT NULL")
        try db.execute(sql: "DELETE FROM events WHERE kind = 'askRaised' AND json_extract(payload, '$.askRaised._0.kind.plan') IS NOT NULL")
    }

    /// A terminal with a note is a note, its markdown kept here and never in the repo.
    private static func v7Notes(_ db: Database) throws {
        try db.alter(table: "terminals") { t in t.add(column: "note", .text) }
    }

    /// A terminal with a command is a task.
    private static func v6Tasks(_ db: Database) throws {
        try db.alter(table: "terminals") { t in t.add(column: "command", .text) }
    }

    /// A terminal with a URL is a browser.
    private static func v5Browsers(_ db: Database) throws {
        try db.alter(table: "terminals") { t in t.add(column: "url", .text) }
    }

    /// The first message of a draft session, kept while it has text or attachments so the draft
    /// survives a restart.
    private static func v4SessionDrafts(_ db: Database) throws {
        try db.create(table: "session_drafts") { t in
            t.primaryKey("sessionId", .text).references("sessions", onDelete: .cascade)
            t.column("message", .jsonText).notNull()
        }
    }

    /// Rows run from the ⌘K palette, by key (an action id, or an action id and its argument), so
    /// recent ones rank first.
    private static func v3PaletteRecents(_ db: Database) throws {
        try db.create(table: "palette_recents") { t in
            t.primaryKey("key", .text)
            t.column("usedAt", .double).notNull()
        }
    }

    /// The pickers' effort, fast mode and plan mode per session. Model and permission mode live on `sessions`.
    private static func v2TurnSettings(_ db: Database) throws {
        try db.create(table: "session_turn_settings") { t in
            t.primaryKey("sessionId", .text).references("sessions", onDelete: .cascade)
            t.column("effort", .text)
            t.column("fastMode", .boolean).notNull()
            t.column("planMode", .boolean).notNull()
        }
    }

    /// Messages waiting for a session's turn to end, in send order.
    private static func v2Queue(_ db: Database) throws {
        try db.create(table: "queued_messages") { t in
            t.primaryKey("id", .text)
            t.belongsTo("session", onDelete: .cascade).notNull()
            t.column("position", .integer).notNull()
            t.column("message", .jsonText).notNull()
            t.column("createdAt", .double).notNull()
        }
    }

    /// Prompts sent in each project, for ↑ in the composer.
    private static func v2PromptHistory(_ db: Database) throws {
        try db.create(table: "prompt_history") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("project", onDelete: .cascade).notNull()
            t.column("text", .text).notNull()
            t.column("sentAt", .double).notNull()
        }
    }

    private static func v1(_ db: Database) throws {
        try db.create(table: "projects") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("rootPath", .text).notNull()
            t.column("swatch", .text).notNull()
            t.column("setupScriptPath", .text)
            t.column("defaultProvider", .text).notNull()
            t.column("defaultBranch", .text).notNull()
        }

        try db.create(table: "sessions") { t in
            t.primaryKey("id", .text)
            t.belongsTo("project", onDelete: .cascade).notNull()
            t.column("host", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("model", .text).notNull()
            t.column("permissionMode", .text).notNull()
            t.column("title", .text).notNull()
            t.column("worktreePath", .text).notNull()
            t.column("usesWorktree", .boolean).notNull()
            t.column("branch", .text).notNull()
            t.column("baseBranch", .text).notNull()
            t.column("nativeID", .text)
            t.column("createdAt", .double).notNull()
            t.column("lastActivityAt", .double).notNull()
            t.column("lastSeenAt", .double)
            t.column("runState", .jsonText).notNull()
            t.column("failureMessage", .text)
            t.column("lifecycle", .text).notNull().indexed()
            t.column("outcome", .jsonText)
            t.column("pullRequest", .jsonText)
            t.column("filesTouched", .jsonText).notNull()
        }

        // Asks carry only what was asked. Answers, and so secret values, are never written here.
        try db.create(table: "asks") { t in
            t.column("id", .text).notNull()
            t.belongsTo("session", onDelete: .cascade).notNull()
            t.column("position", .integer).notNull()
            t.column("kind", .jsonText).notNull()
            t.column("createdAt", .double).notNull()
            t.column("status", .text).notNull()
            t.primaryKey(["sessionId", "id"])
        }

        try db.create(table: "events") { t in
            t.autoIncrementedPrimaryKey("id")
            t.belongsTo("session", onDelete: .cascade).notNull()
            t.column("sequence", .integer).notNull()
            t.column("time", .double).notNull()
            t.column("kind", .text).notNull()
            t.column("payload", .jsonText).notNull()
            t.uniqueKey(["sessionId", "sequence"])
        }

        // rowid matches events.id. Only message text and tool summaries are indexed.
        try db.create(virtualTable: "eventSearch", using: FTS5()) { t in
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("text")
        }
        try db.execute(sql: """
            CREATE TRIGGER events_delete_search AFTER DELETE ON events BEGIN
                DELETE FROM eventSearch WHERE rowid = old.id;
            END
            """)

        try db.create(table: "terminals") { t in
            t.primaryKey("id", .text)
            t.belongsTo("project", onDelete: .cascade).notNull()
            t.column("workingDirectory", .text).notNull()
            t.belongsTo("session", onDelete: .setNull)
            t.column("title", .text).notNull()
            t.column("state", .text).notNull()
            t.column("lastExitCode", .integer)
            t.column("createdAt", .double).notNull()
        }

        try db.create(table: "layouts") { t in
            t.column("arrangement", .text).notNull()
            t.column("itemKind", .text).notNull()
            t.column("itemId", .text).notNull()
            t.column("x", .double).notNull()
            t.column("y", .double).notNull()
            t.primaryKey(["arrangement", "itemKind", "itemId"])
        }

        try db.create(table: "groups") { t in
            t.primaryKey("id", .text)
            t.column("origin", .jsonText).notNull()
        }

        try db.create(table: "group_members") { t in
            t.belongsTo("group", inTable: "groups", onDelete: .cascade).notNull()
            t.column("itemKind", .text).notNull()
            t.column("itemId", .text).notNull()
            t.primaryKey(["groupId", "itemKind", "itemId"])
        }

        try db.create(table: "settings") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }
    }
}
