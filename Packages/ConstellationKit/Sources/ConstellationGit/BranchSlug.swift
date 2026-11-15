import Foundation

public enum BranchSlug {
    public static let prefix = "constellation/"

    /// Lowercase words from the prompt, at most five, joined by hyphens.
    public static func make(from prompt: String) -> String {
        let folded = prompt.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        let words = folded
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .prefix(5)
            .map { String($0.prefix(20)) }
        return words.isEmpty ? "session" : words.joined(separator: "-")
    }
}
