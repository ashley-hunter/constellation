import Foundation

/// What a task's card says about its last run, read from the tail of its terminal output.
public enum TaskOutput {
    /// The output as plain lines: escape sequences and carriage-return redraws gone, blanks dropped.
    public static func lines(_ text: String) -> [String] {
        let plain = text.replacing(/\u{1B}(\[[0-9;?]*[ -\/]*[@-~]|\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)|[@-Z\\-_=>])/, with: "")
            // A terminal's \r\n is one Character in Swift, so it's made a plain \n before splitting.
            .replacing("\r\n", with: "\n")
        return plain.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            // A progress bar redrawn with \r keeps only its last state.
            let shown = line.split(separator: "\r").last.map(String.init) ?? ""
            let trimmed = shown.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Up to `limit` lines saying why a run failed: the first lines that read as a failure (a ✗, a
    /// FAIL, an error), else the last lines it printed before the prompt came back.
    public static func failureLines(_ text: String, limit: Int = 3) -> [String] {
        let all = lines(text).filter { !isPrompt($0) }
        let failing = all.enumerated().filter { _, line in isFailure(line) }
        guard let first = failing.first?.offset else { return Array(all.suffix(limit)) }
        // The failing line and what follows it, which is usually the expectation and the value.
        return Array(all[first...].prefix(limit))
    }

    private static func isFailure(_ line: String) -> Bool {
        line.hasPrefix("✗") || line.hasPrefix("✕") || line.hasPrefix("×") || line.hasPrefix("FAIL")
            || line.range(of: #"(?i)^(error|err!|fatal)\b|\berror:|\bfailed\b"#, options: .regularExpression) != nil
    }

    /// A shell prompt line, as zsh, bash and the like draw them.
    private static func isPrompt(_ line: String) -> Bool {
        // zsh's `user@host dir %`, not a progress figure like `100%`.
        line.range(of: #"^(➜|❯)|[$#❯]$|\S+@\S+.*%$"#, options: .regularExpression) != nil
    }
}
