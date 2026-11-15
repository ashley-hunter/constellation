import Foundation

/// `git diff` output read into files, hunks and lines, with removed and added lines paired up and
/// the words that changed between them picked out.
public struct UnifiedDiff: Hashable, Sendable {
    public var files: [FileDiff]

    public init(files: [FileDiff]) {
        self.files = files
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    /// Every line across every hunk, context included: how big the diff is to show.
    public var lineCount: Int { files.reduce(0) { $0 + $1.lineCount } }

    public init(parsing text: String) {
        var parser = UnifiedDiffParser(text)
        self.files = parser.parse()
    }
}

public struct FileDiff: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case added, deleted, renamed, modified, binary
    }

    /// Nil for an added file.
    public var oldPath: String?
    /// Nil for a deleted file.
    public var newPath: String?
    public var status: Status
    public var hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, status: Status, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.hunks = hunks
    }

    /// The path to show: where the file is now, or where it was if it's gone.
    public var path: String { newPath ?? oldPath ?? "" }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .added }) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == .removed }) } }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

public struct DiffHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// What git prints after the closing `@@`, usually the enclosing function. Nil when there's none.
    public var context: String?
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, context: String?, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.context = context
        self.lines = lines
    }

    /// The hunk side by side: context on both sides, each removed line beside the added line it
    /// pairs with, and a blank side where a run has nothing to pair with.
    public var rows: [DiffRow] {
        var rows: [DiffRow] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else {
                rows.append(DiffRow(old: index, new: index))
                index += 1
                continue
            }
            let removed = run(of: .removed, from: index)
            let added = run(of: .added, from: removed.upperBound)
            for offset in 0..<max(removed.count, added.count) {
                rows.append(DiffRow(
                    old: offset < removed.count ? removed.lowerBound + offset : nil,
                    new: offset < added.count ? added.lowerBound + offset : nil
                ))
            }
            index = max(added.upperBound, index + 1)
        }
        return rows
    }

    func run(of kind: DiffLine.Kind, from start: Int) -> Range<Int> {
        var end = start
        while end < lines.count, lines[end].kind == kind { end += 1 }
        return start..<end
    }
}

/// One row of the side-by-side view, as indices into the hunk's lines. A context line is both.
public struct DiffRow: Hashable, Sendable {
    public var old: Int?
    public var new: Int?
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context, added, removed
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Without the leading marker.
    public var text: String
    /// Character offsets into `text` that differ from the line it's paired with. Empty for context,
    /// for unpaired lines, and for pairs with too little in common to be worth marking.
    public var changes: [Range<Int>]
    /// Followed by git's "\ No newline at end of file".
    public var missingNewline: Bool

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String, changes: [Range<Int>] = [], missingNewline: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.changes = changes
        self.missingNewline = missingNewline
    }
}

// MARK: Parsing

private struct UnifiedDiffParser {
    private let lines: [Substring]
    private var position = 0

    init(_ text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        self.lines = lines
    }

    mutating func parse() -> [FileDiff] {
        var files: [FileDiff] = []
        while position < lines.count {
            if lines[position].hasPrefix("diff --git ") {
                files.append(parseFile())
            } else {
                position += 1
            }
        }
        return files
    }

    private mutating func parseFile() -> FileDiff {
        let paths = Self.headerPaths(lines[position].dropFirst("diff --git ".count))
        position += 1
        var oldPath: String? = paths?.old
        var newPath: String? = paths?.new
        var isAdded = false, isDeleted = false, isRenamed = false, isBinary = false
        var hunks: [DiffHunk] = []

        while position < lines.count, !lines[position].hasPrefix("diff --git ") {
            let line = lines[position]
            if line.hasPrefix("@@") {
                hunks.append(parseHunk())
                continue
            }
            if line.hasPrefix("new file mode") {
                isAdded = true
            } else if line.hasPrefix("deleted file mode") {
                isDeleted = true
            } else if let path = line.value(after: "rename from ") {
                isRenamed = true
                oldPath = Self.unquote(path)
            } else if let path = line.value(after: "rename to ") {
                isRenamed = true
                newPath = Self.unquote(path)
            } else if let path = line.value(after: "--- ") {
                oldPath = Self.sidePath(path, prefix: "a/")
            } else if let path = line.value(after: "+++ ") {
                newPath = Self.sidePath(path, prefix: "b/")
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
            position += 1
        }

        if isAdded { oldPath = nil }
        if isDeleted { newPath = nil }
        let status: FileDiff.Status =
            if isBinary { .binary }
            else if isAdded { .added }
            else if isDeleted { .deleted }
            else if isRenamed { .renamed }
            else { .modified }
        return FileDiff(oldPath: oldPath, newPath: newPath, status: status, hunks: hunks)
    }

    private mutating func parseHunk() -> DiffHunk {
        let header = Self.hunkHeader(lines[position])
        position += 1
        var hunk = DiffHunk(
            oldStart: header.oldStart, oldCount: header.oldCount,
            newStart: header.newStart, newCount: header.newCount,
            context: header.context, lines: []
        )
        var (oldNumber, newNumber) = (header.oldStart, header.newStart)
        var (oldLeft, newLeft) = (header.oldCount, header.newCount)

        // The counts say where the hunk ends, so a removed "--- x" line isn't mistaken for a header.
        while position < lines.count, oldLeft > 0 || newLeft > 0 || lines[position].hasPrefix("\\") {
            let line = lines[position]
            let text = String(line.dropFirst())
            switch line.first {
            case "+":
                hunk.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: text))
                newNumber += 1
                newLeft -= 1
            case "-":
                hunk.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: text))
                oldNumber += 1
                oldLeft -= 1
            case "\\":
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].missingNewline = true }
            case " ", nil:
                hunk.lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                return Self.markingChanges(in: hunk)
            }
            position += 1
        }
        return Self.markingChanges(in: hunk)
    }

    private static func markingChanges(in hunk: DiffHunk) -> DiffHunk {
        var hunk = hunk
        for row in hunk.rows {
            guard let old = row.old, let new = row.new, old != new else { continue }
            let changes = WordDiff.changes(hunk.lines[old].text, hunk.lines[new].text)
            hunk.lines[old].changes = changes.old
            hunk.lines[new].changes = changes.new
        }
        return hunk
    }

    /// `@@ -12,7 +12,9 @@ func name()`. A count left out means one line.
    private static func hunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, context: String?) {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        func range(_ index: Int) -> (Int, Int) {
            guard parts.indices.contains(index) else { return (0, 0) }
            let numbers = parts[index].dropFirst().split(separator: ",")
            return (Int(numbers.first ?? "") ?? 0, numbers.count > 1 ? Int(numbers[1]) ?? 0 : 1)
        }
        let (oldStart, oldCount) = range(1)
        let (newStart, newCount) = range(2)
        var context: String?
        if parts.count > 3 {
            let tail = parts[3].drop { $0 != "@" }.drop { $0 == "@" }.trimmingCharacters(in: .whitespaces)
            context = tail.isEmpty ? nil : tail
        }
        return (oldStart, oldCount, newStart, newCount, context)
    }

    /// The paths in `diff --git a/x b/x`, a fallback for files with no `---` and `+++` lines, such as
    /// binaries and pure renames. Unquoted paths with spaces are split where the two halves match.
    private static func headerPaths(_ rest: Substring) -> (old: String, new: String)? {
        if rest.hasPrefix("\"") {
            guard let close = closingQuote(in: rest) else { return nil }
            let old = unquote(rest[...close])
            let new = unquote(rest[rest.index(after: close)...].drop { $0 == " " })
            return (strip(old, "a/"), strip(new, "b/"))
        }
        if let quote = rest.range(of: " \"b/") {
            return (strip(String(rest[..<quote.lowerBound]), "a/"), strip(unquote(rest[rest.index(after: quote.lowerBound)...]), "b/"))
        }
        let halves = rest.ranges(of: " b/").map { (String(rest[..<$0.lowerBound]), String(rest[rest.index(after: $0.lowerBound)...])) }
        guard let (old, new) = halves.first(where: { strip($0.0, "a/") == strip($0.1, "b/") }) ?? halves.first else { return nil }
        return (strip(old, "a/"), strip(new, "b/"))
    }

    private static func sidePath(_ value: Substring, prefix: String) -> String? {
        var value = value
        if !value.hasPrefix("\""), let tab = value.firstIndex(of: "\t") { value = value[..<tab] }
        let path = unquote(value)
        return path == "/dev/null" ? nil : strip(path, prefix)
    }

    private static func strip(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func closingQuote(in text: Substring) -> Substring.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index == text.endIndex { return nil }
            } else if text[index] == "\"" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Git quotes a path with unusual characters in C style, with UTF-8 bytes as octal escapes.
    static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return String(text) }
        var bytes: [UInt8] = []
        var scalars = Array(text.dropFirst().dropLast().utf8)[...]
        while let byte = scalars.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = scalars.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = scalars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    scalars.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension Substring {
    func value(after prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

// MARK: Word changes

/// Which words differ between a removed line and the added line that replaced it: the tokens left
/// over after a longest common subsequence of the two.
enum WordDiff {
    /// Beyond this many token comparisons a pair isn't worth the work, and gets no word marks.
    static let workLimit = 40_000

    static func changes(_ old: String, _ new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let a = tokens(old), b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= workLimit else { return ([], []) }

        // lengths[i][j]: the common subsequence of a[i...] and b[j...], built from the end.
        let width = b.count + 1
        var lengths = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i * width + j] = a[i].text == b[j].text
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : Swift.max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }

        var keptA = [Bool](repeating: false, count: a.count), keptB = [Bool](repeating: false, count: b.count)
        var (i, j) = (0, 0)
        while i < a.count, j < b.count {
            if a[i].text == b[j].text {
                keptA[i] = true
                keptB[j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        // Lines that share only spaces and punctuation are rewrites: the line tint says enough.
        let sharesWords = zip(a, keptA).contains { $0.1 && $0.0.isWord }
        guard sharesWords else { return ([], []) }
        return (ranges(a, kept: keptA), ranges(b, kept: keptB))
    }

    struct Token {
        var text: Substring
        var range: Range<Int>
        var isWord: Bool
    }

    /// Runs of letters and digits, runs of spaces, and each other character on its own.
    static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var index = line.startIndex
        while index < line.endIndex {
            let first = line[index]
            let kind = first.isLetter || first.isNumber || first == "_" ? 0 : first.isWhitespace ? 1 : 2
            var end = line.index(after: index)
            var length = 1
            if kind != 2 {
                while end < line.endIndex {
                    let next = line[end]
                    let same = kind == 0 ? next.isLetter || next.isNumber || next == "_" : next.isWhitespace
                    guard same else { break }
                    end = line.index(after: end)
                    length += 1
                }
            }
            tokens.append(Token(text: line[index..<end], range: offset..<(offset + length), isWord: kind == 0))
            offset += length
            index = end
        }
        return tokens
    }

    /// The tokens not kept, joined into ranges. A space between two changed tokens joins them, and
    /// spaces at either end of a range are left out unless they're all it has.
    private static func ranges(_ tokens: [Token], kept: [Bool]) -> [Range<Int>] {
        var spans: [ClosedRange<Int>] = []
        for index in tokens.indices where !kept[index] {
            if let last = spans.last, last.upperBound == index - 1 || (last.upperBound == index - 2 && !tokens[index - 1].isWord && tokens[index - 1].text.allSatisfy(\.isWhitespace)) {
                spans[spans.count - 1] = last.lowerBound...index
            } else {
                spans.append(index...index)
            }
        }
        return spans.map { span in
            let isSpace = { (index: Int) in tokens[index].text.allSatisfy(\.isWhitespace) }
            var (first, last) = (span.lowerBound, span.upperBound)
            while first < last, isSpace(first) { first += 1 }
            while last > first, isSpace(last) { last -= 1 }
            return tokens[first].range.lowerBound..<tokens[last].range.upperBound
        }
    }
}
