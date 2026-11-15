import ConstellationCore
import Foundation
import Testing
@testable import ConstellationStore

@Suite struct UsageStoreTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func addsUpPerSessionAndPerDay() throws {
        let store = try Store.inMemory()
        let (claude, codex) = (UUID(), UUID())
        try store.addUsage(TokenUsage(inputTokens: 10, outputTokens: 1, costUSD: 0.5, contextTokens: 11, contextWindow: 200_000), sessionID: claude, provider: .claudeCode, at: date(day: 3, hour: 23), calendar: calendar)
        try store.addUsage(TokenUsage(inputTokens: 20, outputTokens: 2, costUSD: 0.25, contextTokens: 33), sessionID: claude, provider: .claudeCode, at: date(day: 4, hour: 1), calendar: calendar)
        try store.addUsage(TokenUsage(inputTokens: 100, outputTokens: 5, cachedInputTokens: 50), sessionID: codex, provider: .codex, at: date(day: 4, hour: 2), calendar: calendar)

        let sessions = try store.sessionUsage()
        #expect(sessions[claude]?.totals == UsageTotals(inputTokens: 30, outputTokens: 3, costUSD: 0.75))
        #expect(sessions[claude]?.contextTokens == 33)
        #expect(sessions[claude]?.contextWindow == 200_000)
        #expect(sessions[codex]?.totals.costUSD == nil)
        #expect(sessions[codex]?.totals.totalTokens == 155)

        let days = try store.dailyUsage(since: "2026-11-01")
        #expect(days.map(\.day) == ["2026-11-04", "2026-11-04", "2026-11-03"])
        #expect(days[0].provider == .claudeCode)
        #expect(days[0].totals == UsageTotals(inputTokens: 20, outputTokens: 2, costUSD: 0.25))
        #expect(days[1].totals.totalTokens == 155)
        #expect(try store.dailyUsage(since: "2026-11-04").count == 2)
    }

    @Test func anOlderReportNeverRewindsTheContext() throws {
        let store = try Store.inMemory()
        let id = UUID()
        try store.addUsage(TokenUsage(inputTokens: 1, outputTokens: 1, contextTokens: 500), sessionID: id, provider: .codex, at: date(day: 4, hour: 2), calendar: calendar)
        try store.addUsage(TokenUsage(inputTokens: 1, outputTokens: 1, contextTokens: 400), sessionID: id, provider: .codex, at: date(day: 4, hour: 1), calendar: calendar)
        #expect(try store.sessionUsage()[id]?.contextTokens == 500)
        #expect(try store.sessionUsage()[id]?.totals.totalTokens == 4)
    }
}
