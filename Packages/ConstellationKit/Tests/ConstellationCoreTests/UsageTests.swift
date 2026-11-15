import ConstellationCore
import Foundation
import Testing

@Suite struct UsageTests {
    @Test func reportsAddUpAndKeepTheLatestContext() {
        var usage = SessionUsage()
        usage.add(TokenUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 1_000, costUSD: 0.02, contextTokens: 1_110, contextWindow: 200_000))
        usage.add(TokenUsage(inputTokens: 50, outputTokens: 5, cachedInputTokens: 1_100, costUSD: 0.01, contextTokens: 1_165))
        #expect(usage.totals.totalTokens == 2_265)
        #expect(abs((usage.totals.costUSD ?? 0) - 0.03) < 1e-9)
        #expect(usage.contextTokens == 1_165)
        #expect(usage.contextWindow == 200_000)
        #expect(usage.contextFraction == 1_165.0 / 200_000)
    }

    @Test func codexTotalsHaveNoCost() {
        var usage = SessionUsage()
        usage.add(TokenUsage(inputTokens: 900, outputTokens: 100))
        #expect(usage.totals.costUSD == nil)
        #expect(usage.summary == "1k tokens")
        #expect(SessionUsage().summary == nil)
        #expect(usage.contextFraction == nil)
    }

    @Test func formatsTokensAndCost() {
        #expect(UsageFormat.tokens(950) == "950")
        #expect(UsageFormat.tokens(12_340) == "12.3k")
        #expect(UsageFormat.tokens(250_000) == "250k")
        #expect(UsageFormat.tokens(1_260_000) == "1.3M")
        #expect(UsageFormat.cost(0.004) == "<$0.01")
        #expect(UsageFormat.cost(0) == "$0.00")
        #expect(UsageFormat.cost(12.5) == "$12.50")
    }

    @Test func dayKeysUseTheLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
        #expect(DailyUsage.dayKey(for: date, calendar: calendar) == "2026-03-07")
    }

    @Test func oldUsageEventsStillDecode() throws {
        let json = #"{"inputTokens":1,"outputTokens":2,"cachedInputTokens":3}"#
        let usage = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(usage == TokenUsage(inputTokens: 1, outputTokens: 2, cachedInputTokens: 3))
    }
}
