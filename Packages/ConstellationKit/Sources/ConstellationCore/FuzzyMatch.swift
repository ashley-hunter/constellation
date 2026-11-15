import Foundation

/// Subsequence matching for the `/` and `@` menus. Matches at word starts, runs of matched
/// characters and matches in a path's last component score higher; shorter candidates break ties.
public enum FuzzyMatch {
    /// Nil when the query's characters don't all appear, in order, in the candidate. Case is ignored.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate)
        let lowered = Array(candidate.lowercased())
        guard lowered.count == haystack.count else { return nil }
        let nameStart = (lowered.lastIndex(of: "/") ?? -1) + 1

        // Prefer matching inside the last component: try from there first, then from the start.
        for start in nameStart > 0 ? [nameStart, 0] : [0] {
            if var score = greedyScore(needle, in: lowered, original: haystack, from: start) {
                if start == nameStart { score += 20 }
                return score - candidate.count / 4
            }
        }
        return nil
    }

    /// The candidates that match, best first, at most `limit`. An empty query keeps their order.
    public static func rank(_ query: String, _ candidates: [String], limit: Int) -> [String] {
        rank(query, candidates, limit: limit) { $0 }
    }

    public static func rank<T>(_ query: String, _ candidates: [T], limit: Int, text: (T) -> String) -> [T] {
        guard !query.isEmpty else { return Array(candidates.prefix(limit)) }
        let scored = candidates.enumerated().compactMap { index, candidate in
            score(query, in: text(candidate)).map { (candidate, $0, index) }
        }
        return scored
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .prefix(limit)
            .map(\.0)
    }

    private static func greedyScore(_ needle: [Character], in lowered: [Character], original: [Character], from start: Int) -> Int? {
        var score = 0
        var position = start
        var previousMatch = -2
        for character in needle {
            guard let found = lowered[position...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previousMatch + 1 { score += 8 }
            if isWordStart(found, in: original) { score += 10 }
            previousMatch = found
            position = found + 1
        }
        return score
    }

    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        if "/._- :".contains(previous) { return true }
        return previous.isLowercase && text[index].isUppercase
    }
}
