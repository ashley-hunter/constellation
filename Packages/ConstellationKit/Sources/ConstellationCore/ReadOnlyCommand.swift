import Foundation

/// Decides whether a shell command line only reads, so "Ask for risky" can run it without asking.
/// Conservative: anything it can't parse, or any command it doesn't know, counts as not read-only.
public enum ReadOnlyCommand {
    public static func isReadOnly(_ line: String) -> Bool {
        // Substitutions run commands of their own, even inside double quotes.
        for marker in ["$(", "`", "<(", ">("] where line.contains(marker) { return false }
        guard let tokens = tokenize(line) else { return false }
        var segments: [[Token]] = [[]]
        for token in tokens {
            if case .op(let op) = token, separators.contains(op) {
                segments.append([])
            } else {
                segments[segments.count - 1].append(token)
            }
        }
        let commands = segments.filter { !$0.isEmpty }
        guard !commands.isEmpty else { return false }
        return commands.allSatisfy(segmentIsReadOnly)
    }

    // MARK: Segments

    private static let separators: Set<String> = ["&&", "||", ";", "|", "|&", "&", "\n"]

    private static func segmentIsReadOnly(_ tokens: [Token]) -> Bool {
        var words: [String] = []
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case .word(let word):
                words.append(word)
            case .op(let op):
                index += 1
                guard index < tokens.count, case .word(let target) = tokens[index] else { return false }
                switch op {
                case "<": break
                case ">&", "<&": guard target.allSatisfy(\.isNumber) || target == "/dev/null" else { return false }
                case ">", ">>", ">|", "&>", "&>>": guard target == "/dev/null" else { return false }
                default: return false
                }
            }
            index += 1
        }
        // Leading `NAME=value` assignments only set the environment.
        while let first = words.first, isAssignment(first) { words.removeFirst() }
        guard let command = words.first else { return true }
        return commandIsReadOnly(command, Array(words.dropFirst()))
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: Commands

    private static let plain: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "echo", "printf", "pwd", "which", "stat",
        "du", "df", "diff", "jq", "basename", "dirname", "realpath", "cut", "tr", "cd", "true",
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "/bin/sh", "/bin/bash", "/bin/zsh"]

    private static func commandIsReadOnly(_ command: String, _ arguments: [String]) -> Bool {
        // `node --version` and the like. Only bare names, so a project script never counts.
        if arguments == ["--version"], !command.contains("/") { return true }
        if plain.contains(command) { return true }
        switch command {
        case "find":
            let writing: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
            return !arguments.contains(where: writing.contains)
        case "rg":
            return !arguments.contains { $0.hasPrefix("--pre") }
        case "tree":
            return !arguments.contains("-o")
        case "file":
            return !arguments.contains { $0 == "-C" || $0 == "--compile" }
        case "sort":
            return !arguments.contains { $0.hasPrefix("-o") || $0.hasPrefix("--output") }
        case "sed":
            return sedIsReadOnly(arguments)
        case "awk":
            return awkIsReadOnly(arguments)
        case "git":
            return gitIsReadOnly(arguments)
        case _ where shells.contains(command):
            // Codex wraps commands in `/bin/zsh -lc '...'`.
            guard arguments.count == 2, ["-c", "-lc"].contains(arguments[0]) else { return false }
            return isReadOnly(arguments[1])
        default:
            return false
        }
    }

    /// Only `sed -n` with print scripts like `1,20p` or `$p`: no in-place edits, no `w` or `e`.
    private static func sedIsReadOnly(_ arguments: [String]) -> Bool {
        guard arguments.contains("-n") else { return false }
        var scripts: [String] = []
        var expectsScript = false
        for argument in arguments {
            if expectsScript {
                scripts.append(argument)
                expectsScript = false
            } else if argument == "-e" {
                expectsScript = true
            } else if argument.hasPrefix("-") {
                guard ["-n", "-E", "-r"].contains(argument) else { return false }
            } else if scripts.isEmpty {
                scripts.append(argument)
            }
        }
        let address = #"(\d+|\$)"#
        let print = try! Regex(#"^\#(address)(,\#(address))?p$"#)
        return !scripts.isEmpty && scripts.allSatisfy { script in
            script.split(separator: ";").allSatisfy { (try? print.wholeMatch(in: String($0).trimmingCharacters(in: .whitespaces))) != nil }
        }
    }

    /// No `system()`, pipes, output redirection or `getline`. Comparisons with `>` ask too.
    private static func awkIsReadOnly(_ arguments: [String]) -> Bool {
        if arguments.contains(where: { $0 == "-i" || $0.hasPrefix("--include") || $0.hasPrefix("-f") }) { return false }
        return !arguments.contains { argument in
            ["system", "|", ">", "getline"].contains { argument.contains($0) }
        }
    }

    private static func gitIsReadOnly(_ arguments: [String]) -> Bool {
        var rest = arguments[...]
        // `-C dir` and `--no-pager` only; `-c` could set a pager or alias that runs anything.
        while let first = rest.first, first.hasPrefix("-") {
            switch first {
            case "--no-pager": rest = rest.dropFirst()
            case "-C": rest = rest.dropFirst(2)
            default: return false
            }
        }
        guard let subcommand = rest.first else { return false }
        let options = Array(rest.dropFirst())
        if options.contains(where: { $0.hasPrefix("--output") }) { return false }
        switch subcommand {
        case "status", "log", "diff", "show", "rev-parse", "ls-files", "ls-tree", "blame", "describe", "rev-list",
             "cat-file", "shortlog", "merge-base":
            return true
        case "branch":
            let changing: Set<String> = [
                "-d", "-D", "-m", "-M", "-c", "-C", "-f", "-u", "--delete", "--move", "--copy", "--force",
                "--set-upstream-to", "--unset-upstream", "--edit-description",
            ]
            if options.contains(where: { changing.contains($0) || $0.hasPrefix("--set-upstream-to=") }) { return false }
            // A bare name creates a branch; with a listing flag it is a pattern or commit instead.
            let listing: Set<String> = ["-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
            return !options.contains { !$0.hasPrefix("-") } || options.contains(where: listing.contains)
        case "remote":
            return options.isEmpty || options == ["-v"] || options == ["--verbose"] || options.first == "get-url"
        case "stash":
            return options.first == "list"
        default:
            return false
        }
    }

    // MARK: Tokens

    private enum Token: Equatable {
        case word(String)
        case op(String)
    }

    /// Splits a line into words and operators the way a POSIX shell would, keeping quoted text
    /// together. Nil when a quote is left open or the line has a comment or here-document.
    private static func tokenize(_ line: String) -> [Token]? {
        var tokens: [Token] = []
        var word: String?
        let chars = Array(line)
        var index = 0
        func flush() {
            if let current = word { tokens.append(.word(current)) }
            word = nil
        }
        while index < chars.count {
            let char = chars[index]
            switch char {
            case " ", "\t":
                flush()
            case "\n", ";":
                flush()
                tokens.append(.op(String(char)))
            case "'":
                guard let close = chars[(index + 1)...].firstIndex(of: "'") else { return nil }
                word = (word ?? "") + String(chars[(index + 1)..<close])
                index = close
            case "\"":
                var text = ""
                index += 1
                while index < chars.count, chars[index] != "\"" {
                    if chars[index] == "\\", index + 1 < chars.count, "\"\\$`\n".contains(chars[index + 1]) { index += 1 }
                    text.append(chars[index])
                    index += 1
                }
                guard index < chars.count else { return nil }
                word = (word ?? "") + text
            case "\\":
                index += 1
                guard index < chars.count else { return nil }
                if chars[index] != "\n" { word = (word ?? "") + String(chars[index]) }
            case "#" where word == nil:
                return nil
            case "&", "|":
                flush()
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if next == char || (char == "|" && next == "&") {
                    tokens.append(.op(String([char, next!])))
                    index += 1
                } else if char == "&", next == ">" {
                    let appends = index + 2 < chars.count && chars[index + 2] == ">"
                    tokens.append(.op(appends ? "&>>" : "&>"))
                    index += appends ? 2 : 1
                } else {
                    tokens.append(.op(String(char)))
                }
            case ">", "<":
                // A file descriptor number before the operator belongs to it.
                if let current = word, current.allSatisfy(\.isNumber) { word = nil }
                flush()
                var op = String(char)
                while index + 1 < chars.count, op.count < 3, ">&|<".contains(chars[index + 1]) {
                    op.append(chars[index + 1])
                    index += 1
                }
                tokens.append(.op(op))
            default:
                word = (word ?? "") + String(char)
            }
            index += 1
        }
        flush()
        return tokens
    }
}
