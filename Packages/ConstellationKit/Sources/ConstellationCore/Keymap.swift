import Foundation

/// The bindings the app ships with, and its global hotkeys.
public struct KeymapDefaults: Sendable {
    public var bindings: [KeyRule]
    public var globals: [KeyRule]

    public init(bindings: [KeyRule], globals: [KeyRule] = []) {
        self.bindings = bindings
        self.globals = globals
    }

    func rules(global: Bool) -> [KeyRule] {
        global ? globals : bindings
    }
}

/// The keys in effect: the defaults, with the file's binds and unbinds applied.
public struct Keymap: Sendable {
    public enum Source: Hashable, Sendable {
        case `default`
        /// A `bind` or `global` line in keys.conf.
        case file(line: Int)
    }

    public struct Entry: Hashable, Sendable {
        public var rule: KeyRule
        public var source: Source

        public init(_ rule: KeyRule, source: Source = .default) {
            self.rule = rule
            self.source = source
        }
    }

    /// What typing a sequence of keys means so far.
    public enum Match: Equatable, Sendable {
        case none
        /// The keys start longer bindings. `exact` are the ones they already complete, run if nothing follows.
        case prefix(exact: [Entry])
        case exact([Entry])
    }

    /// Desktop bindings in the order keys try them: the file's first, then the defaults.
    public let bindings: [Entry]
    public let globals: [Entry]
    /// The file's unreadable lines, plus binds to actions that don't exist.
    public let problems: [KeysConfig.Problem]

    public init(defaults: KeymapDefaults, config: KeysConfig = KeysConfig(parsing: ""), knownActions: Set<String>? = nil) {
        var problems = config.problems
        var resolved: [Bool: (file: [Entry], defaults: [Entry])] = [:]
        for global in [false, true] {
            var file: [Entry] = []
            var builtIn = defaults.rules(global: global).map { Entry($0) }
            for (line, directive) in config.directives {
                switch directive {
                case .bind(let rule, global) where knownActions?.contains(rule.action) == false:
                    problems.append(KeysConfig.Problem(line: line, message: "unknown action \u{201C}\(rule.action)\u{201D}"))
                case .bind(let rule, global):
                    file.removeAll { $0.rule == rule }
                    if !builtIn.contains(where: { $0.rule == rule }) { file.append(Entry(rule, source: .file(line: line))) }
                case .unbind(let target, global):
                    file.removeAll { target.matches($0.rule) }
                    builtIn.removeAll { target.matches($0.rule) }
                default:
                    break
                }
            }
            resolved[global] = (file, builtIn)
        }
        bindings = resolved[false].map { $0.file + $0.defaults } ?? []
        globals = resolved[true].map { $0.file + $0.defaults } ?? []
        self.problems = problems.sorted { $0.line < $1.line }
    }

    // MARK: Matching keys

    /// What the keys typed so far match.
    public func match(_ typed: [KeyStroke]) -> Match {
        guard !typed.isEmpty else { return .none }
        var exact: [Entry] = []
        var longer = false
        for entry in bindings where entry.rule.strokes.count >= typed.count {
            guard entry.rule.strokes.starts(with: typed) else { continue }
            if entry.rule.strokes.count == typed.count { exact.append(entry) } else { longer = true }
        }
        if longer { return .prefix(exact: exact) }
        return exact.isEmpty ? .none : .exact(exact)
    }

    // MARK: Querying

    public func entries(for action: String, argument: String?, global: Bool = false) -> [Entry] {
        (global ? globals : bindings).filter { $0.rule.action == action && $0.rule.argument == argument }
    }

    /// Other bindings the keys would clash with: the same keys, or one a prefix of the other.
    public func conflicts(with strokes: [KeyStroke], excluding action: String, argument: String?, global: Bool = false) -> [Entry] {
        (global ? globals : bindings).filter { entry in
            guard entry.rule.action != action || entry.rule.argument != argument else { return false }
            let shorter = min(entry.rule.strokes.count, strokes.count)
            return Array(entry.rule.strokes.prefix(shorter)) == Array(strokes.prefix(shorter))
        }
    }

    /// Whether the file changes an action's keys from the defaults.
    public func isCustomized(_ action: String, argument: String?, global: Bool = false, defaults: KeymapDefaults) -> Bool {
        let current = Set(entries(for: action, argument: argument, global: global).map(\.rule.strokes))
        let original = Set(defaults.rules(global: global).filter { $0.action == action && $0.argument == argument }.map(\.strokes))
        return current != original
    }
}
