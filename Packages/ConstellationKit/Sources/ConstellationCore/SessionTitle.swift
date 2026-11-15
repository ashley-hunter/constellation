import Foundation

/// A session's title, made from its first prompt without asking a model: the change it names in a
/// few words, e.g. "GET /products/:id endpoint" for "Add a GET /products/:id endpoint to server.js
/// that returns 404...". Identifiers, paths and quoted names are kept as written.
public enum SessionTitle {
    /// At most this many characters, cut on a word.
    static let maxLength = 32
    static let maxWords = 5

    public static func make(from prompt: String) -> String {
        var words = firstSentence(of: prompt).split(separator: " ").map(String.init)
        words = droppingFiller(words)
        words = cutAtClause(words)
        words = words.filter { !articles.contains($0.lowercased()) }
        words = capped(words)
        while let last = words.last, words.count > 1, connectors.contains(last.lowercased()) { words.removeLast() }
        guard !words.isEmpty else { return fallback(prompt) }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        if let first = title.first, first.isLowercase, words[0].allSatisfy(\.isLetter) {
            title = first.uppercased() + title.dropFirst()
        }
        return title.isEmpty ? fallback(prompt) : title
    }

    /// Asks and greetings in front of the request.
    private static let fillerPhrases: [[String]] = [
        ["hey"], ["hi"], ["hello"], ["ok"], ["okay"], ["so"], ["please"], ["pls"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["i", "want", "to"], ["i'd", "like", "to"], ["i", "would", "like", "to"], ["i", "need", "to"],
        ["we", "need", "to"], ["let's"], ["lets"], ["help", "me"], ["go", "ahead", "and"],
        ["i", "want"], ["i'd", "like"], ["i", "need"],
    ]
    /// Verbs that say only that something new is wanted, dropped when an article follows.
    private static let makingVerbs: Set<String> = ["add", "create", "implement", "build", "write", "introduce"]
    private static let articles: Set<String> = ["a", "an", "the"]
    /// Words that start the detail after the change itself.
    private static let clauseWords: Set<String> = ["that", "which", "so", "because", "where", "when", "after", "before", "since", "while", "and"]
    /// Words that point at where the change goes, dropped with a file or path after them.
    private static let placeWords: Set<String> = ["to", "in", "into", "inside", "on"]
    /// Words a title shouldn't end on.
    private static let connectors: Set<String> = ["a", "an", "the", "to", "for", "of", "in", "on", "with", "and", "or", "into", "from", "by", "at"]

    /// The first line, up to its first full stop, question or exclamation mark followed by a space.
    private static func firstSentence(of prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var sentence = ""
        var quote: Character?
        for (index, character) in zip(line.indices, line) {
            if "\"'`".contains(character), quote == nil || quote == character {
                // An apostrophe inside a word isn't a quote.
                let isApostrophe = character == "'" && quote == nil && index > line.startIndex && line[line.index(before: index)].isLetter
                if !isApostrophe { quote = quote == nil ? character : nil }
            }
            let next = line.index(after: index)
            if quote == nil, ".?!".contains(character), next == line.endIndex || line[next] == " " { break }
            if quote == nil, character == ",", fillerOnly(sentence) { sentence = ""; continue }
            sentence.append(character)
        }
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    /// "Hey," or "Ok so," before the request.
    private static func fillerOnly(_ text: String) -> Bool {
        let words = text.split(separator: " ").map { $0.lowercased() }
        return !words.isEmpty && droppingFiller(words).isEmpty
    }

    private static func droppingFiller(_ words: [String]) -> [String] {
        var words = words
        var dropped = true
        while dropped {
            dropped = false
            let lower = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            if let phrase = fillerPhrases.first(where: { lower.starts(with: $0) }) {
                words.removeFirst(phrase.count)
                dropped = true
            } else if lower.count > 2, makingVerbs.contains(lower[0]), articles.contains(lower[1]) || lower[1] == "new" {
                words.removeFirst(2)
                dropped = true
            }
        }
        return words
    }

    /// Up to the first clause word or comma outside quotes, and without a trailing "to server.js".
    private static func cutAtClause(_ words: [String]) -> [String] {
        var kept: [String] = []
        var quote: Character?
        for word in words {
            let lower = word.lowercased()
            if quote == nil, kept.count >= 2 {
                if clauseWords.contains(lower) { break }
                if placeWords.contains(lower), let next = words.dropFirst(kept.count + 1).first, isPlace(next) { break }
            }
            kept.append(word)
            for character in word where "\"`".contains(character) { quote = quote == nil ? character : nil }
            if quote == nil, word.hasSuffix(","), kept.count >= 2 {
                kept[kept.count - 1].removeLast()
                break
            }
        }
        return kept
    }

    /// A file or folder: has a dot inside or a slash, and isn't a route like /products/:id.
    private static func isPlace(_ word: String) -> Bool {
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'.,"))
        guard !bare.hasPrefix("/") else { return false }
        return bare.contains("/") || bare.dropFirst().contains(".")
    }

    private static func capped(_ words: [String]) -> [String] {
        var kept: [String] = []
        var length = 0
        for word in words.prefix(maxWords) {
            let added = kept.isEmpty ? word.count : word.count + 1
            guard length + added <= maxLength || kept.isEmpty else { break }
            kept.append(word)
            length += added
        }
        return kept
    }

    /// The first line cut at a word, for a prompt that is all filler.
    private static func fallback(_ prompt: String) -> String {
        let line = (prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        guard line.count > maxLength else { return line.isEmpty ? "New session" : line }
        let cut = line.prefix(maxLength)
        return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "…"
    }
}
