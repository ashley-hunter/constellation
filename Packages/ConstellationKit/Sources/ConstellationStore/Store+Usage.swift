import ConstellationCore
import Foundation
import GRDB

extension Schema {
    /// Each session's spend and context, and per-day totals by provider. Day totals have no foreign
    /// key, so they outlive the sessions and projects that spent them.
    static func v2Usage(_ db: Database) throws {
        try db.create(table: "session_usage") { t in
            t.primaryKey("sessionId", .text)
            t.column("inputTokens", .integer).notNull().defaults(to: 0)
            t.column("outputTokens", .integer).notNull().defaults(to: 0)
            t.column("cachedInputTokens", .integer).notNull().defaults(to: 0)
            t.column("costUSD", .double)
            t.column("contextTokens", .integer)
            t.column("contextWindow", .integer)
            t.column("updatedAt", .double).notNull()
        }
        try db.create(table: "usage_days") { t in
            t.column("day", .text).notNull()
            t.column("provider", .text).notNull()
            t.column("inputTokens", .integer).notNull().defaults(to: 0)
            t.column("outputTokens", .integer).notNull().defaults(to: 0)
            t.column("cachedInputTokens", .integer).notNull().defaults(to: 0)
            t.column("costUSD", .double)
            t.primaryKey(["day", "provider"])
        }
    }
}

extension Store {
    /// Adds one usage report to its session and to the day it happened. Counts are added in SQL and
    /// the context only moves forward in time, so writes may land in any order.
    public func addUsage(
        _ usage: TokenUsage,
        sessionID: UUID,
        provider: Provider,
        at date: Date,
        calendar: Calendar = .current
    ) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO session_usage
                    (sessionId, inputTokens, outputTokens, cachedInputTokens, costUSD, contextTokens, contextWindow, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET
                    inputTokens = inputTokens + excluded.inputTokens,
                    outputTokens = outputTokens + excluded.outputTokens,
                    cachedInputTokens = cachedInputTokens + excluded.cachedInputTokens,
                    costUSD = CASE WHEN excluded.costUSD IS NULL THEN costUSD ELSE coalesce(costUSD, 0) + excluded.costUSD END,
                    contextTokens = CASE WHEN excluded.updatedAt >= updatedAt
                        THEN coalesce(excluded.contextTokens, contextTokens) ELSE contextTokens END,
                    contextWindow = CASE WHEN excluded.updatedAt >= updatedAt
                        THEN coalesce(excluded.contextWindow, contextWindow) ELSE contextWindow END,
                    updatedAt = max(updatedAt, excluded.updatedAt)
                """, arguments: [
                    sessionID.uuidString, usage.inputTokens, usage.outputTokens, usage.cachedInputTokens,
                    usage.costUSD, usage.contextTokens, usage.contextWindow, date.timeIntervalSinceReferenceDate,
                ])
            try db.execute(sql: """
                INSERT INTO usage_days (day, provider, inputTokens, outputTokens, cachedInputTokens, costUSD)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, provider) DO UPDATE SET
                    inputTokens = inputTokens + excluded.inputTokens,
                    outputTokens = outputTokens + excluded.outputTokens,
                    cachedInputTokens = cachedInputTokens + excluded.cachedInputTokens,
                    costUSD = CASE WHEN excluded.costUSD IS NULL THEN costUSD ELSE coalesce(costUSD, 0) + excluded.costUSD END
                """, arguments: [
                    DailyUsage.dayKey(for: date, calendar: calendar), provider.rawValue,
                    usage.inputTokens, usage.outputTokens, usage.cachedInputTokens, usage.costUSD,
                ])
        }
    }

    public func sessionUsage() throws -> [UUID: SessionUsage] {
        try database.read { db in
            var result: [UUID: SessionUsage] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM session_usage") {
                guard let id = UUID(uuidString: row["sessionId"]) else { continue }
                result[id] = SessionUsage(
                    totals: Self.totals(row),
                    contextTokens: row["contextTokens"],
                    contextWindow: row["contextWindow"]
                )
            }
            return result
        }
    }

    /// Days from `firstDay` (a `yyyy-MM-dd` key) on, newest first.
    public func dailyUsage(since firstDay: String) throws -> [DailyUsage] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM usage_days WHERE day >= ? ORDER BY day DESC, provider", arguments: [firstDay])
                .compactMap { row in
                    guard let provider = Provider(rawValue: row["provider"]) else { return nil }
                    return DailyUsage(day: row["day"], provider: provider, totals: Self.totals(row))
                }
        }
    }

    private static func totals(_ row: Row) -> UsageTotals {
        UsageTotals(
            inputTokens: row["inputTokens"],
            outputTokens: row["outputTokens"],
            cachedInputTokens: row["cachedInputTokens"],
            costUSD: row["costUSD"]
        )
    }
}
