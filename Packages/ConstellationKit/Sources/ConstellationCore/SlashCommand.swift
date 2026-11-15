import Foundation

/// An entry in the composer's `/` menu: a Claude Code slash command or skill, or a Codex skill.
public struct SlashCommand: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case builtIn, command, skill
    }

    /// Where it was found. Repo entries win over user ones with the same name.
    public enum Scope: String, Hashable, Sendable {
        case repo, user, system, builtIn
    }

    public var name: String
    public var description: String
    public var kind: Kind
    public var scope: Scope
    /// The command file or `SKILL.md`. Codex needs it to send a skill input item.
    public var path: String?

    public init(name: String, description: String, kind: Kind, scope: Scope, path: String? = nil) {
        self.name = name
        self.description = description
        self.kind = kind
        self.scope = scope
        self.path = path
    }

    public var id: String { "\(kind.rawValue):\(name)" }

    /// What choosing it puts in the composer. Claude Code reads `/name` as written; Codex reads
    /// `$name` as a skill mention.
    public func insertion(for provider: Provider) -> String {
        switch provider {
        case .claudeCode: "/\(name) "
        case .codex: "$\(name) "
        }
    }

    /// The `$name` skill mentions in a Codex message, in order, without repeats.
    public static func codexSkillMentions(in text: String) -> [String] {
        var names: [String] = []
        for match in text.matches(of: /(?:^|\s)\$([A-Za-z0-9][A-Za-z0-9_.:-]*)(?=\s|$)/) {
            let name = String(match.output.1)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}
