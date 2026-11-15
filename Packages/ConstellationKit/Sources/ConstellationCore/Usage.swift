import Foundation

/// Tokens and cost added up over usage reports.
public struct UsageTotals: Hashable, Codable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedInputTokens = 0
    /// Nil until a report carries a cost, so Codex-only totals show no cost rather than $0.
    public var costUSD: Double?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD
    }

    public var totalTokens: Int { inputTokens + outputTokens + cachedInputTokens }

    public mutating func add(_ usage: TokenUsage) {
        add(UsageTotals(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            costUSD: usage.costUSD
        ))
    }

    public mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        if let cost = other.costUSD { costUSD = (costUSD ?? 0) + cost }
    }
}

/// A session's spend so far and how full its context window was at the last report.
public struct SessionUsage: Hashable, Codable, Sendable {
    public var totals = UsageTotals()
    public var contextTokens: Int?
    public var contextWindow: Int?

    public init(totals: UsageTotals = UsageTotals(), contextTokens: Int? = nil, contextWindow: Int? = nil) {
        self.totals = totals
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
    }

    public mutating func add(_ usage: TokenUsage) {
        totals.add(usage)
        if let tokens = usage.contextTokens { contextTokens = tokens }
        if let window = usage.contextWindow, window > 0 { contextWindow = window }
    }

    /// 0...1, or nil while the window or the context isn't known.
    public var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    /// "12.3k tokens · $0.04", or nil before the first report.
    public var summary: String? {
        guard totals.totalTokens > 0 || totals.costUSD != nil else { return nil }
        let tokens = "\(UsageFormat.tokens(totals.totalTokens)) tokens"
        return totals.costUSD.map { "\(tokens) · \(UsageFormat.cost($0))" } ?? tokens
    }
}

/// One provider's totals for one local calendar day.
public struct DailyUsage: Hashable, Sendable {
    /// `yyyy-MM-dd` in the local calendar.
    public var day: String
    public var provider: Provider
    public var totals: UsageTotals

    public init(day: String, provider: Provider, totals: UsageTotals) {
        self.day = day
        self.provider = provider
        self.totals = totals
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public enum UsageFormat {
    /// "950", "12.3k", "1.2M".
    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: compact(Double(count) / 1_000) + "k"
        default: compact(Double(count) / 1_000_000) + "M"
        }
    }

    /// "$0.04", "$12.50", and "<$0.01" for anything smaller than a cent.
    public static func cost(_ dollars: Double) -> String {
        if dollars > 0, dollars < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }

    private static func compact(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }
}
