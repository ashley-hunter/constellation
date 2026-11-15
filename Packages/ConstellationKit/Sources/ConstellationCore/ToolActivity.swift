import Foundation

extension ToolCall {
    /// A call in plain words, split so the verb can sit quieter than what it acted on.
    public struct Phrase: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case search, read, edit, command, web, other
        }

        public var kind: Kind
        /// "Searching for", while it runs.
        public var present: String
        /// "Searched for", once it has.
        public var past: String
        /// "minimumReleaseAge". Empty when the verb says it all ("Updated its plan").
        public var object: String
    }

    /// What the call did, for a trace line in the transcript: "Edited LoginView.swift", "Ran swift
    /// test". Nil for Constellation's own MCP tools, which are bookkeeping rather than work.
    public var phrase: Phrase? {
        if name.hasPrefix("mcp__constellation__") || name.hasPrefix("constellation.") { return nil }
        let subject = summary.trimmingCharacters(in: .whitespaces)
        let file = (subject as NSString).lastPathComponent
        switch name {
        case "Read": return Phrase(kind: .read, present: "Reading", past: "Read", object: file)
        case "Edit", "MultiEdit", "NotebookEdit": return Phrase(kind: .edit, present: "Editing", past: "Edited", object: file)
        case "Write": return Phrase(kind: .edit, present: "Writing", past: "Wrote", object: file)
        case "apply_patch":
            let files = self.files.map { ($0 as NSString).lastPathComponent }
            return Phrase(kind: .edit, present: "Editing", past: "Edited", object: files.isEmpty ? "files" : files.joined(separator: ", "))
        case "Bash", "shell", "local_shell": return Phrase(kind: .command, present: "Running", past: "Ran", object: subject)
        case "Grep": return Phrase(kind: .search, present: "Searching for", past: "Searched for", object: subject)
        case "Glob": return Phrase(kind: .search, present: "Finding", past: "Looked for", object: subject)
        case "WebFetch": return Phrase(kind: .web, present: "Reading", past: "Read", object: URL(string: subject)?.host() ?? subject)
        case "WebSearch", "web_search": return Phrase(kind: .web, present: "Searching the web for", past: "Searched the web for", object: subject)
        case "Task", "Agent": return Phrase(kind: .other, present: "Running a subagent", past: "Ran a subagent", object: "")
        case "TodoWrite": return Phrase(kind: .other, present: "Updating its plan", past: "Updated its plan", object: "")
        case "ToolSearch": return Phrase(kind: .search, present: "Looking up its tools", past: "Looked up its tools", object: "")
        default:
            // mcp__server__tool from Claude Code, server.tool from Codex.
            let parts = name.hasPrefix("mcp__") ? Array(name.components(separatedBy: "__").dropFirst()) : name.components(separatedBy: ".")
            guard parts.count >= 2 else { return Phrase(kind: .other, present: "Using", past: "Used", object: name) }
            let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            return Phrase(kind: .other, present: "Using", past: "Used", object: "\(tool) in \(parts[0])")
        }
    }

    /// What the call is doing, in words for a tile: "Editing LoginView.swift", "Running `swift
    /// test`". Nil for Constellation's own MCP tools.
    public var activity: String? {
        guard let phrase else { return nil }
        guard !phrase.object.isEmpty else { return phrase.present }
        switch phrase.kind {
        case .command: return "\(phrase.present) `\(Self.shortened(phrase.object, to: 40))`"
        case .search, .web: return "\(phrase.present) \(Self.shortened(phrase.object, to: 40))"
        case .read, .edit, .other: return "\(phrase.present) \(phrase.object)"
        }
    }

    private static func shortened(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }

    /// A run of calls in one line, for a folded trace: "Ran 2 commands, read 1 file".
    public static func summary(of kinds: [Phrase.Kind]) -> String {
        let order: [(Phrase.Kind, String, String, String)] = [
            (.command, "ran", "command", "commands"), (.edit, "edited", "file", "files"),
            (.read, "read", "file", "files"), (.search, "searched", "time", "times"),
            (.web, "fetched", "page", "pages"), (.other, "used", "tool", "tools"),
        ]
        let parts = order.compactMap { kind, verb, one, many -> String? in
            let count = kinds.count { $0 == kind }
            return count == 0 ? nil : "\(verb) \(count) \(count == 1 ? one : many)"
        }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
