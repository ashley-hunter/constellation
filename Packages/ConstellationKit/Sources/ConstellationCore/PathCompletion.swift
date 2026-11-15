import Foundation

/// A folder path typed into a field, completed the way a shell completes it.
public enum PathCompletion {
    /// The text up to and including the last /, and the segment after it.
    public static func split(_ text: String) -> (directory: String, leaf: String) {
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        return (String(text[...slash]), String(text[text.index(after: slash)...]))
    }

    /// Where `text` points: ~ is home, / is absolute, anything else is below `base`.
    public static func resolve(_ text: String, base: URL, home: URL = URL.homeDirectory) -> URL {
        let url: URL
        if text == "~" {
            url = home
        } else if text.hasPrefix("~/") {
            url = home.appending(path: String(text.dropFirst(2)), directoryHint: .isDirectory)
        } else if text.hasPrefix("/") {
            url = URL(filePath: text, directoryHint: .isDirectory)
        } else {
            url = base.appending(path: text, directoryHint: .isDirectory)
        }
        return url.standardizedFileURL
    }

    /// The names that start with `leaf`, ignoring case. Hidden ones only once the leaf starts with a dot.
    public static func matches(_ names: [String], leaf: String) -> [String] {
        let lower = leaf.lowercased()
        let showsHidden = leaf.hasPrefix(".")
        return names.filter { $0.lowercased().hasPrefix(lower) && (showsHidden || !$0.hasPrefix(".")) }
    }

    /// Tab: one match is complete (enter it); several extend the leaf to their common prefix, or
    /// nil when that adds nothing.
    public static func completion(_ matches: [String], leaf: String) -> (name: String, isComplete: Bool)? {
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return (first, true) }
        var prefix = Array(first)
        for name in matches.dropFirst() {
            let characters = Array(name)
            var length = 0
            while length < min(prefix.count, characters.count), prefix[length].lowercased() == characters[length].lowercased() {
                length += 1
            }
            prefix = Array(prefix.prefix(length))
        }
        return prefix.count > leaf.count ? (String(prefix), false) : nil
    }
}
