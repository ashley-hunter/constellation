import Foundation

/// Whether a first message reads as a question, which a new session answers in the project folder
/// rather than a new worktree. A small fixed rule, so the draft's chip can follow it as you type.
public enum QuestionPrompt {
    /// Said to the agent, out of sight, when a question runs in the project folder.
    public static let instruction = "This is a question. Answer it without changing any files; if a change is needed, say so and stop."

    static let openers: [[String]] = [
        "what", "why", "how", "where", "when", "which", "who", "is", "are", "does", "do", "can", "could",
        "should", "explain", "describe", "summarise", "summarize", "list", "find", "review",
    ].map { [$0] } + [["show", "me"], ["tell", "me"]]

    /// Asking for words back anywhere in it: "Run the tests and tell me what fails".
    static let asks: [[String]] = [["tell", "me"], ["show", "me"], ["explain"]]

    public static func isQuestion(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed.lowercased().split { !$0.isLetter }.map(String.init)
        if openers.contains(where: { words.starts(with: $0) }) { return true }
        return asks.contains { phrase in
            words.indices.contains { words[$0...].starts(with: phrase) }
        }
    }
}
