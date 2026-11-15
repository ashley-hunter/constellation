import Foundation

/// One key press: a key name and its modifiers. Letters are lowercase with `.shift` for capitals;
/// other characters are as typed ("?", ":"), without `.shift`. Named keys: return, escape, space,
/// tab, delete, left, right, up, down.
public struct KeyStroke: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    public var key: String
    public var modifiers: Modifiers = []

    public static let namedKeys: Set<String> = ["return", "escape", "space", "tab", "delete", "left", "right", "up", "down"]

    /// "cmd+shift+c", "J" (shift+j), "escape", "1".
    public init?(_ spec: String) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard var key = parts.popLast(), !key.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            switch part.lowercased() {
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        if key.count == 1, let letter = key.first, letter.isLetter, letter.isUppercase {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        self.init(key: key, modifiers: modifiers)
    }

    public init(key: String, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// ⌘ chords, esc and tab still reach the desktop while a text field has focus. ⌘↵ stays with
    /// the composer, where it steers, and ⌘ with the arrows or ⌫ stays with the text, where it
    /// moves to or deletes to a line's end. With ⌃ too they mean nothing to text, so they reach
    /// the desktop (the split screen's moves).
    public var worksWhileEditing: Bool {
        if modifiers.contains(.command), !modifiers.contains(.control), ["return", "delete", "left", "right", "up", "down"].contains(key) { return false }
        return modifiers.contains(.command) || key == "escape" || key == "tab"
    }

    public var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let symbols = [
            "return": "↵", "escape": "esc", "space": "space", "tab": "⇥", "delete": "⌫",
            "left": "←", "right": "→", "up": "↑", "down": "↓",
        ]
        let key = symbols[key] ?? (key.count == 1 ? key.uppercased() : key)
        // Plain letters read better lowercase, as the tile footers show them.
        return modifiers.isEmpty && key.count == 1 ? text + key.lowercased() : text + key
    }
}

/// A key sequence that runs an action, with an optional argument for it.
public struct KeyBinding: Hashable, Sendable {
    public var strokes: [KeyStroke]
    public var argument: String?

    /// Strokes separated by spaces: "cmd+k", "g g", "cmd+k shift+p".
    public init(_ spec: String, argument: String? = nil) {
        // An optional interpolated into the spec, a mistake made twice: it never matches a key.
        assert(!spec.contains("Optional("), "Key binding built from an optional: \(spec)")
        strokes = spec.split(separator: " ").compactMap { KeyStroke(String($0)) }
        self.argument = argument
        assert(!strokes.isEmpty, "Bad key binding \(spec)")
    }

    public init(strokes: [KeyStroke], argument: String? = nil) {
        self.strokes = strokes
        self.argument = argument
    }

    public var label: String {
        strokes.map(\.label).joined(separator: " ")
    }
}
