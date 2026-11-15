import Foundation

/// Walking back through a project's earlier prompts with ↑ and forward with ↓.
public struct PromptHistoryWalk: Hashable, Sendable {
    /// Newest first.
    public let entries: [String]
    /// The entry shown now. Nil before the first ↑.
    public private(set) var index: Int?

    public init(entries: [String]) {
        self.entries = entries
    }

    public var current: String? {
        index.map { entries[$0] }
    }

    /// The next older prompt, or nil at the oldest.
    public mutating func older() -> String? {
        let next = (index ?? -1) + 1
        guard next < entries.count else { return nil }
        index = next
        return entries[next]
    }

    /// The next newer prompt, or nil once past the newest, which ends the walk.
    public mutating func newer() -> String? {
        guard let index, index > 0 else {
            self.index = nil
            return nil
        }
        self.index = index - 1
        return entries[index - 1]
    }
}

public enum PromptHistory {
    /// How many prompts each project keeps.
    public static let limit = 500

    /// `entries` (newest first) after sending `text`: it moves to the front, appearing once.
    public static func recording(_ text: String, in entries: [String]) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return entries }
        return Array(([text] + entries.filter { $0 != text }).prefix(limit))
    }
}
