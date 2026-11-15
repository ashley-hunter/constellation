import Foundation

/// Collects keys into sequences ("g g", "cmd+k c") and says when one is complete.
public struct KeySequencer: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// A binding is complete: try these in order.
        case run([Keymap.Entry])
        /// Waiting for the next key. `fallback` runs if none comes, for keys that are both a binding
        /// and the start of a longer one.
        case wait(fallback: [Keymap.Entry])
        case unmatched
    }

    public private(set) var pending: [KeyStroke] = []

    public init() {}

    public mutating func feed(_ stroke: KeyStroke, in keymap: Keymap) -> Outcome {
        let typed = pending + [stroke]
        switch keymap.match(typed) {
        case .exact(let entries):
            pending = []
            return .run(entries)
        case .prefix(let exact):
            pending = typed
            return .wait(fallback: exact)
        case .none:
            guard !pending.isEmpty else { return .unmatched }
            // A key that doesn't continue the sequence starts afresh.
            pending = []
            return feed(stroke, in: keymap)
        }
    }

    /// No key came in time: what the pending keys complete on their own, if anything.
    public mutating func timeOut(in keymap: Keymap) -> [Keymap.Entry] {
        defer { pending = [] }
        if case .prefix(let exact) = keymap.match(pending) { return exact }
        return []
    }

    public mutating func cancel() {
        pending = []
    }
}

/// Hint labels for jumping to tiles.
public enum JumpHints {
    public static let homeRow = Array("asdfghjkl").map(String.init)

    /// ⌘-hold badges: 1-9, then 0, for the first ten tiles.
    public static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    /// The ⌘-hold label for each of `count` targets: single digits while ten or fewer. Beyond that
    /// the first nine keep 1-9, as they are the most urgent, and the rest start with 0 (01 ... 00,
    /// then 001 ... 099 past nineteen), so no label is the start of another and a jump never waits
    /// to see if another digit is coming.
    public static func digitLabels(count: Int) -> [String] {
        guard count > digits.count else { return Array(digits.prefix(count)) }
        let rest = count - 9
        let tail = rest <= digits.count
            ? digits.prefix(rest).map { "0" + $0 }
            : (1...min(rest, 99)).map { String(format: "0%02d", $0) }
        return Array(digits.prefix(9)) + tail
    }

    /// Home-row labels, one letter each while they last, then two, as Vimium does. No label is the
    /// start of another, so a label is complete as soon as it is typed.
    public static func labels(count: Int, alphabet: [String] = homeRow) -> [String] {
        guard count > 0, alphabet.count > 1 else { return [] }
        var labels = alphabet
        var next = 0
        while labels.count - next < count {
            let prefix = labels[next]
            next += 1
            labels += alphabet.map { prefix + $0 }
        }
        return Array(labels[next..<(next + count)])
    }

    public enum Resolution: Equatable, Sendable {
        case complete(Int)
        case partial
        case none
    }

    /// What the letters typed so far pick out among the labels.
    public static func resolve(_ typed: String, among labels: [String]) -> Resolution {
        if let index = labels.firstIndex(of: typed) { return .complete(index) }
        return labels.contains { $0.hasPrefix(typed) } ? .partial : .none
    }

    /// The tile a digit names: "1" is the first, "0" the tenth.
    public static func index(ofDigit digit: String) -> Int? {
        digits.firstIndex(of: digit)
    }
}
