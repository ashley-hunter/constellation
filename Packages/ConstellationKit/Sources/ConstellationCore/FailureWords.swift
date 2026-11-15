import Foundation

/// A failure as a card says it: plain words in place of an errno, a status code or a stack line.
/// The raw message stays on the session for its panel.
public enum FailureWords {
    public static func summary(_ message: String?, reason: FailureReason) -> String {
        switch reason {
        case .auth: return "Signed out. Sign in again to carry on."
        case .usageLimit: return "Usage limit reached."
        // The agent's own account of what went wrong is already in words.
        case .reportedFailure: return message ?? "It reported that it couldn't finish."
        case .launch(let stage):
            guard let message else { return start(stage) }
            return plain(message) ?? (looksRaw(message) ? start(stage) : message)
        case .turnError, .processExited:
            guard let message else { return "Failed." }
            return plain(message) ?? (looksRaw(message) ? "Something went wrong." : message)
        }
    }

    private static func start(_ stage: LaunchStage) -> String {
        switch stage {
        case .fetch: "Couldn't fetch the latest code."
        case .worktree: "Couldn't create the worktree."
        case .setup: "The setup script failed."
        case .starting: "The agent couldn't start."
        }
    }

    /// Known kinds of error, matched loosely, as each provider and tool spells them differently.
    private static let kinds: [(needles: [String], words: String)] = [
        (["couldn't resume", "couldn’t resume"], "Couldn't pick the session back up. Retry to start it again."),
        (["rate limit", "rate_limit", "too many requests", " 429"], "Rate limited. Try again in a moment."),
        (["overloaded", " 529", " 503", "service unavailable"], "The service is busy. Try again in a moment."),
        (["unauthorized", "unauthenticated", "invalid api key", "invalid_api_key", " 401"], "Not signed in, or the key was refused."),
        (["econnrefused", "econnreset", "etimedout", "enotfound", "fetch failed", "socket hang up", "network", "timed out"], "Couldn't reach the network."),
        (["enospc", "no space left"], "The disk is full."),
        (["eacces", "eperm", "permission denied", "operation not permitted"], "It wasn't allowed to open a file."),
        (["enoent", "no such file"], "A file or folder it needed is missing."),
        (["traceback", "panic:", "fatal error", "uncaught", "unhandled"], "The agent crashed."),
        (["exited with code", "exit code", "app-server exited", "sigkill", "sigterm", "killed"], "The agent stopped unexpectedly."),
    ]

    private static func plain(_ message: String) -> String? {
        let lowered = " " + message.lowercased()
        return kinds.first { kind in kind.needles.contains { lowered.contains($0) } }?.words
    }

    /// Reads as a developer's error rather than a sentence: a `TypeError:`-style name, an NSError
    /// dump, JSON, a hex address or an errno.
    private static func looksRaw(_ message: String) -> Bool {
        message.contains("Error Domain=") || message.contains("{") || message.contains("0x") || message.lowercased().contains("errno")
            || message.contains("couldn’t be completed") || message.contains("couldn't be completed")
            || message.range(of: #"\([A-Za-z]+\.[A-Za-z]+Error\b"#, options: .regularExpression) != nil
            || message.range(of: #"\b[A-Z]?[a-z]*(Error|Exception):"#, options: .regularExpression) != nil
    }
}
