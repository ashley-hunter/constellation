import Foundation

/// Edits Settings makes to keys.conf. Each changes only the lines it has to, adds new lines at the
/// end, and writes only what differs from the defaults, so the file stays short and hand edits stay put.
extension KeysConfig {
    /// Gives an action (with its argument) exactly these keys; none unbinds it.
    public mutating func setKeys(_ keys: [[KeyStroke]], for action: String, argument: String?, global: Bool = false, defaults: KeymapDefaults) {
        reset(action, argument: argument, global: global, defaults: defaults)
        let current = Keymap(defaults: defaults, config: self).entries(for: action, argument: argument, global: global).map(\.rule.strokes)
        for strokes in current where !keys.contains(strokes) {
            append(.unbind(KeyTarget(strokes, action: action, argument: argument), global: global))
        }
        for strokes in keys where !current.contains(strokes) {
            append(.bind(KeyRule(strokes, action, argument: argument), global: global))
        }
    }

    /// Frees keys for another binding, the Replace in a conflict: the clashing lines of the file go,
    /// and clashing defaults are unbound.
    public mutating func removeConflicts(with strokes: [KeyStroke], keeping action: String, argument: String?, global: Bool = false, defaults: KeymapDefaults) {
        let keymap = Keymap(defaults: defaults, config: self)
        for entry in keymap.conflicts(with: strokes, excluding: action, argument: argument, global: global) {
            let others = keymap.entries(for: entry.rule.action, argument: entry.rule.argument, global: global).map(\.rule.strokes)
            setKeys(others.filter { $0 != entry.rule.strokes }, for: entry.rule.action, argument: entry.rule.argument, global: global, defaults: defaults)
        }
    }

    /// Puts an action back to its default keys, removing the file's lines about it.
    public mutating func reset(_ action: String, argument: String?, global: Bool = false, defaults: KeymapDefaults) {
        let ownLine: (Directive) -> Bool = { directive in
            switch directive {
            case .bind(let rule, global): rule.action == action && rule.argument == argument
            case .unbind(let target, global): target.action == action && target.argument == argument
            case .bind, .unbind: false
            }
        }
        removeLines(where: ownLine)
        splitUnbinds(sparing: action, argument: argument, global: global, defaults: defaults)
    }

    /// An `unbind` that names no action, or names this action with no argument, and so also drops
    /// this action's default keys, is rewritten as one targeted line per other rule it removes.
    private mutating func splitUnbinds(sparing action: String, argument: String?, global: Bool, defaults: KeymapDefaults) {
        let builtIn = defaults.rules(global: global)
        var index = 0
        while index < lines.count {
            guard case .unbind(let target, global)? = lines[index].directive,
                  target.action == nil || (target.action == action && target.argument == nil),
                  builtIn.contains(where: { target.matches($0) && $0.action == action && $0.argument == argument })
            else {
                index += 1
                continue
            }
            let above = KeysConfig(lines: Array(lines[..<index]))
            let removed = Keymap(defaults: defaults, config: above).entries(matching: target, global: global)
                .filter { $0.rule.action != action || $0.rule.argument != argument }
            let comment = lines[index].text
            lines.remove(at: index)
            for (offset, entry) in removed.enumerated() {
                let replacement = Directive.unbind(KeyTarget(target.strokes, action: entry.rule.action, argument: entry.rule.argument), global: global)
                insert(replacement, at: index + offset)
                if offset == 0, let hash = comment.firstIndex(of: "#") { lines[index].text += "  " + comment[hash...] }
            }
            index += removed.count
        }
    }

    /// Every directive goes; comments and blank lines stay.
    public mutating func resetAll() {
        removeLines { _ in true }
    }

    init(lines: [Line]) {
        self.lines = lines
    }
}

extension Keymap {
    func entries(matching target: KeyTarget, global: Bool) -> [Entry] {
        (global ? globals : bindings).filter { target.matches($0.rule) }
    }
}

extension KeysConfig {
    /// The file written on first launch: how it works, then every default, commented out.
    public static func template(defaults: KeymapDefaults, titles: [String: String] = [:]) -> String {
        var text = """
        # Constellation keys. Settings > Keyboard edits this file, and changes here apply when you save.
        # Lines you don't write keep their defaults, listed below commented out.
        #
        #   bind = MODIFIERS, KEYS, action[, argument]      modifiers: CMD ALT CTRL SHIFT
        #   unbind = MODIFIERS, KEYS[, action[, argument]]   without an action, unbinds every action on the keys
        #   global = MODIFIERS, KEY, action[, argument]      works from any app
        #   unglobal = MODIFIERS, KEY[, action[, argument]]
        #
        # Modifiers apply to the last key. KEYS can be a sequence: "G G", or "CMD+K S".

        """
        text += "\n# Bindings\n"
        text += lines(for: defaults.bindings, global: false, titles: titles)
        text += "\n# Global hotkeys\n"
        text += lines(for: defaults.globals, global: true, titles: titles)
        return text
    }

    private static func lines(for rules: [KeyRule], global: Bool, titles: [String: String]) -> String {
        let formatted = rules.map { format(.bind($0, global: global)) }
        let width = (formatted.map(\.count).max() ?? 0) + 2
        return zip(rules, formatted).map { rule, line in
            guard let title = titles[rule.action] else { return "# \(line)\n" }
            return "# \(line.padding(toLength: width, withPad: " ", startingAt: 0))# \(title)\n"
        }.joined()
    }
}
