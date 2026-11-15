import Foundation

/// The word being typed at the end of a composer draft that opens a menu: `/` at the start for
/// commands, `@` after a space or at the start for files.
public struct ComposerToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command, mention
    }

    public var kind: Kind
    /// What follows the `/` or `@`.
    public var query: String
    /// Where the token starts in the draft, counted in characters.
    public var offset: Int

    public init(kind: Kind, query: String, offset: Int) {
        self.kind = kind
        self.query = query
        self.offset = offset
    }

    /// The token at the end of `text`, if any. The composer has no caret position, so only the end counts.
    public static func trailing(in text: String) -> ComposerToken? {
        if let match = text.wholeMatch(of: /(\s*)\/(\S*)/) {
            return ComposerToken(kind: .command, query: String(match.output.2), offset: match.output.1.count)
        }
        if let match = text.firstMatch(of: /(?:^|\s)@(\S*)$/) {
            let query = String(match.output.1)
            return ComposerToken(kind: .mention, query: query, offset: text.count - query.count - 1)
        }
        return nil
    }

    /// The draft with this token replaced by `insertion`.
    public func replacing(in text: String, with insertion: String) -> String {
        String(text.prefix(offset)) + insertion
    }
}
