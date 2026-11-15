import ConstellationCore
import Foundation

/// The slash commands and skills a Claude Code session can run: built-ins that work in `-p` mode,
/// then `.claude/commands` and `.claude/skills` from the repo and from your home folder.
public enum ClaudeCommandCatalog {
    /// Built-ins that do something useful in a headless (`-p`) session.
    public static let builtIns: [SlashCommand] = [
        ("compact", "Summarise the conversation so far to free up context"),
        ("context", "Show what is using the context window"),
        ("init", "Write a CLAUDE.md describing this codebase"),
        ("security-review", "Review the pending changes on this branch for security issues"),
    ].map { SlashCommand(name: $0.0, description: $0.1, kind: .builtIn, scope: .builtIn) }

    /// Repo entries come first and hide user entries with the same name; built-ins come last.
    public static func commands(repo: URL?, home: URL = .homeDirectory) -> [SlashCommand] {
        var found: [SlashCommand] = []
        for (root, scope) in [(repo, SlashCommand.Scope.repo), (home, .user)] {
            guard let claude = root?.appending(path: ".claude", directoryHint: .isDirectory) else { continue }
            found += commandFiles(in: claude.appending(path: "commands", directoryHint: .isDirectory), scope: scope)
            found += skills(in: claude.appending(path: "skills", directoryHint: .isDirectory), scope: scope)
        }
        var seen: Set<String> = []
        return (found + builtIns).filter { seen.insert($0.name).inserted }
    }

    /// `commands/frontend/component.md` is `/frontend:component`.
    static func commandFiles(in folder: URL, scope: SlashCommand.Scope) -> [SlashCommand] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let commands = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.compactMap { file -> SlashCommand? in
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            guard path.hasPrefix(base) else { return nil }
            let relative = path.dropFirst(base.count).trimmingPrefix("/").dropLast(3)
            let name = String(relative).replacing("/", with: ":")
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return SlashCommand(name: name, description: description(of: text), kind: .command, scope: scope, path: path)
        }
        return commands.sorted { $0.name < $1.name }
    }

    /// Each folder holding a `SKILL.md`, named by its front matter or else the folder.
    static func skills(in folder: URL, scope: SlashCommand.Scope) -> [SlashCommand] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let skills = folders.compactMap { skillFolder -> SlashCommand? in
            let file = skillFolder.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let name = frontMatter(of: text)["name"].flatMap { $0.isEmpty ? nil : $0 } ?? skillFolder.lastPathComponent
            return SlashCommand(name: name, description: description(of: text), kind: .skill, scope: scope, path: file.path(percentEncoded: false))
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// The front matter's `description`, or else the first line of the body.
    static func description(of text: String) -> String {
        if let description = frontMatter(of: text)["description"], !description.isEmpty {
            return description
        }
        let line = body(of: text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingPrefix(/#+\s*/) }
            .first { !$0.isEmpty }
        return line.map(String.init) ?? ""
    }

    /// Top-level `key: value` pairs between `---` lines. Folded (`>`) and literal (`|`) values are
    /// joined onto one line.
    static func frontMatter(of text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingSuffix(\.isWhitespace) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var values: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(value) {
                var block: [String] = []
                while index < end, lines[index].first?.isWhitespace == true || lines[index].isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.filter { !$0.isEmpty }.joined(separator: " ")
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    private static func body(of text: String) -> Substring {
        guard text.hasPrefix("---"), let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return text[...]
        }
        return text[close.upperBound...]
    }
}

extension Substring {
    fileprivate func trimmingSuffix(_ predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return self[startIndex..<end]
    }
}
