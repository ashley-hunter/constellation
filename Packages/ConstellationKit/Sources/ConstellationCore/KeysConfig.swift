import Foundation

/// A key bound to an action, as keys.conf writes it and the keymap resolves it.
public struct KeyRule: Hashable, Sendable {
    public var strokes: [KeyStroke]
    public var action: String
    public var argument: String?

    public init(_ strokes: [KeyStroke], _ action: String, argument: String? = nil) {
        self.strokes = strokes
        self.action = action
        self.argument = argument
    }

    public init(_ binding: KeyBinding, _ action: String) {
        self.init(binding.strokes, action, argument: binding.argument)
    }

    public var binding: KeyBinding { KeyBinding(strokes: strokes, argument: argument) }
}

/// What an `unbind` line removes: every binding of its keys, or only one action's (and argument's).
public struct KeyTarget: Hashable, Sendable {
    public var strokes: [KeyStroke]
    public var action: String?
    public var argument: String?

    public init(_ strokes: [KeyStroke], action: String? = nil, argument: String? = nil) {
        self.strokes = strokes
        self.action = action
        self.argument = argument
    }

    public func matches(_ rule: KeyRule) -> Bool {
        rule.strokes == strokes && (action == nil || action == rule.action) && (argument == nil || argument == rule.argument)
    }
}

/// `~/.config/constellation/keys.conf`, kept line by line so edits leave comments, blank lines and
/// ordering alone. Hyprland-like:
///
///     bind = , DOWN, focus.move, down
///     bind = CMD SHIFT, R, git.pr
///     unbind = , X                # every action on x
///     unbind = , R, session.retry # only retry's
///     global = ALT, SPACE, app.summon
///     unglobal = ALT SHIFT, SPACE
///
/// The first field holds modifiers (CMD, ALT, CTRL, SHIFT); they apply to the last key of the
/// second field, which can be a sequence ("G G") whose earlier keys carry their own ("CMD+K S").
/// `style` and `leader` lines, from when there was a Vim keymap too, are passed over.
public struct KeysConfig: Equatable, Sendable {
    public enum Directive: Equatable, Sendable {
        case bind(KeyRule, global: Bool)
        case unbind(KeyTarget, global: Bool)
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        public var directive: Directive?
    }

    public struct Problem: Hashable, Sendable, CustomStringConvertible {
        public var line: Int
        public var message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }

        public var description: String { "line \(line): \(message)" }
    }

    public var lines: [Line]
    /// Lines that could not be read. Each is skipped; the rest of the file still applies.
    public private(set) var problems: [Problem] = []

    public init(parsing text: String) {
        var raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        lines = []
        for (index, line) in raw.enumerated() {
            do throws(ParseError) {
                lines.append(Line(text: line, directive: try Self.directive(in: line)))
            } catch {
                lines.append(Line(text: line, directive: nil))
                problems.append(Problem(line: index + 1, message: error.message))
            }
        }
    }

    public var text: String {
        lines.isEmpty ? "" : lines.map(\.text).joined(separator: "\n") + "\n"
    }

    /// Directives with their 1-based line numbers.
    public var directives: [(line: Int, directive: Directive)] {
        lines.enumerated().compactMap { index, line in line.directive.map { (index + 1, $0) } }
    }

    // MARK: Editing lines

    public mutating func append(_ directive: Directive) {
        lines.append(Line(text: Self.format(directive), directive: directive))
    }

    public mutating func insert(_ directive: Directive, at index: Int) {
        lines.insert(Line(text: Self.format(directive), directive: directive), at: index)
    }

    /// Rewrites one line, keeping its trailing comment.
    public mutating func replace(at index: Int, with directive: Directive) {
        var text = Self.format(directive)
        if let comment = Self.trailingComment(of: lines[index].text) { text += "  " + comment }
        lines[index] = Line(text: text, directive: directive)
    }

    public mutating func removeLines(where shouldRemove: (Directive) -> Bool) {
        lines.removeAll { $0.directive.map(shouldRemove) ?? false }
    }

    // MARK: Reading

    struct ParseError: Error {
        let message: String
    }

    private static func directive(in line: String) throws(ParseError) -> Directive? {
        let content = (line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        guard let equals = content.firstIndex(of: "=") else { throw ParseError(message: "expected \u{201C}name = value\u{201D}") }
        let name = content[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        let value = content[content.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        switch name {
        case "style", "leader":
            return nil
        case "bind", "global":
            let fields = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else { throw ParseError(message: "\(name) needs modifiers, a key and an action") }
            guard fields.count <= 4 else { throw ParseError(message: "too many fields for \(name)") }
            guard !fields[2].isEmpty else { throw ParseError(message: "\(name) needs an action") }
            let strokes = try strokes(modifiers: fields[0], keys: fields[1])
            let argument = fields.count == 4 && !fields[3].isEmpty ? fields[3] : nil
            return .bind(KeyRule(strokes, fields[2], argument: argument), global: name == "global")
        case "unbind", "unglobal":
            let fields = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { throw ParseError(message: "\(name) needs modifiers and a key") }
            guard fields.count <= 4 else { throw ParseError(message: "too many fields for \(name)") }
            let strokes = try strokes(modifiers: fields[0], keys: fields[1])
            let action = fields.count >= 3 && !fields[2].isEmpty ? fields[2] : nil
            let argument = fields.count == 4 && !fields[3].isEmpty ? fields[3] : nil
            return .unbind(KeyTarget(strokes, action: action, argument: argument), global: name == "unglobal")
        default:
            throw ParseError(message: "unknown setting \u{201C}\(name)\u{201D}")
        }
    }

    private static let namedKeys: [String: String] = [
        "space": "space", "return": "return", "enter": "return", "escape": "escape", "esc": "escape",
        "tab": "tab", "delete": "delete", "backspace": "delete",
        "left": "left", "right": "right", "up": "up", "down": "down",
        "comma": ",", "hash": "#", "plus": "+",
    ]

    private static func modifiers(_ field: String) throws(ParseError) -> KeyStroke.Modifiers {
        var modifiers: KeyStroke.Modifiers = []
        let tokens = field.split { $0 == " " || $0 == "_" || $0 == "+" || $0 == "\t" }
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "super": modifiers.insert(.command)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: throw ParseError(message: "unknown modifier \u{201C}\(token)\u{201D}")
            }
        }
        return modifiers
    }

    /// One key, optionally with its own modifiers: "J", "SPACE", "CMD+K".
    private static func stroke(from token: String) throws(ParseError) -> KeyStroke {
        var parts = token.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let name = parts.removeLast()
        let modifiers = try modifiers(parts.joined(separator: " "))
        let lowered = name.lowercased()
        if let named = namedKeys[lowered] { return KeyStroke(key: named, modifiers: modifiers) }
        guard name.count == 1 else { throw ParseError(message: "unknown key \u{201C}\(name)\u{201D}") }
        return KeyStroke(key: lowered, modifiers: modifiers)
    }

    private static func strokes(modifiers field: String, keys: String) throws(ParseError) -> [KeyStroke] {
        let modifiers = try modifiers(field)
        var strokes: [KeyStroke] = []
        for token in keys.split(whereSeparator: \.isWhitespace) {
            strokes.append(try stroke(from: String(token)))
        }
        guard !strokes.isEmpty else { throw ParseError(message: "missing key") }
        strokes[strokes.count - 1].modifiers.formUnion(modifiers)
        return strokes
    }

    private static func trailingComment(of line: String) -> String? {
        guard let hash = line.firstIndex(of: "#"),
              !line[..<hash].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(line[hash...])
    }

    // MARK: Writing

    public static func format(_ directive: Directive) -> String {
        switch directive {
        case .bind(let rule, let global):
            let argument = rule.argument.map { ", \($0)" } ?? ""
            return "\(global ? "global" : "bind") = \(fields(rule.strokes)), \(rule.action)\(argument)"
        case .unbind(let target, let global):
            var text = "\(global ? "unglobal" : "unbind") = \(fields(target.strokes))"
            if let action = target.action {
                text += ", \(action)"
                if let argument = target.argument { text += ", \(argument)" }
            }
            return text
        }
    }

    /// The modifiers and keys fields: "CMD SHIFT, P", ", G G", "CMD, K".
    static func fields(_ strokes: [KeyStroke]) -> String {
        guard let last = strokes.last else { return ", " }
        let modifiers = modifierNames(last.modifiers)
        let keys = strokes.dropLast().map { keyToken($0, withModifiers: true) } + [keyToken(last, withModifiers: false)]
        return modifiers.joined(separator: " ") + ", " + keys.joined(separator: " ")
    }

    private static func modifierNames(_ modifiers: KeyStroke.Modifiers) -> [String] {
        var names: [String] = []
        if modifiers.contains(.command) { names.append("CMD") }
        if modifiers.contains(.option) { names.append("ALT") }
        if modifiers.contains(.control) { names.append("CTRL") }
        if modifiers.contains(.shift) { names.append("SHIFT") }
        return names
    }

    private static func keyToken(_ stroke: KeyStroke, withModifiers: Bool) -> String {
        let name = switch stroke.key {
        case ",": "COMMA"
        case "#": "HASH"
        case "+": "PLUS"
        default: stroke.key.uppercased()
        }
        guard withModifiers else { return name }
        return (modifierNames(stroke.modifiers) + [name]).joined(separator: "+")
    }
}
