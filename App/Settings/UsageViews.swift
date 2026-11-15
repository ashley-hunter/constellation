import ConstellationCore
import SwiftUI

/// How full the context window is, as a short bar and a percentage, then tokens and cost so far.
struct SessionUsageBadge: View {
    let usage: SessionUsage

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = usage.contextFraction {
                HStack(spacing: 6) {
                    ContextBar(fraction: fraction)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .foregroundStyle(fraction >= 0.8 ? Palette.ask : Palette.textSecondary)
                }
                .help(contextHelp)
            }
            if let summary = usage.summary {
                Text(summary).foregroundStyle(Palette.textTertiary)
            }
        }
        .font(.ui(12)).monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private var contextHelp: String {
        guard let tokens = usage.contextTokens, let window = usage.contextWindow else { return "Context window" }
        return "Context window: \(UsageFormat.tokens(tokens)) of \(UsageFormat.tokens(window)) tokens used"
    }
}

struct ContextBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Palette.text.opacity(0.12))
            .frame(width: 40, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fraction >= 0.8 ? Palette.ask : Palette.working)
                    .frame(width: max(2, 40 * fraction), height: 4)
            }
    }
}

extension SessionUsage {
    /// For a tile's hover tooltip: tokens, cost and context on one line.
    var tooltip: String? {
        guard let summary else { return nil }
        guard let fraction = contextFraction else { return summary }
        return "\(summary) · context \(Int((fraction * 100).rounded()))% full"
    }
}
