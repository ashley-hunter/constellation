import Foundation

/// The one notice over the desktop, and what it holds back while its Undo shows (a ⌘W archive,
/// say). Whatever way the notice goes (replaced by another, dismissed or timed out) it hands back
/// what it held to go ahead at once, so nothing waits hidden with no Undo left to bring it back.
public struct NoticeSlot<Held> {
    public struct Notice: Identifiable {
        public let id = UUID()
        public let text: String
        public let held: Held?
    }

    public private(set) var notice: Notice?

    public init() {}

    /// Shows `text`, or nothing. Returns what the notice it replaces was holding, to go ahead now.
    @discardableResult
    public mutating func show(_ text: String?, holding held: Held? = nil) -> Held? {
        let released = notice?.held
        notice = text.map { Notice(text: $0, held: held) }
        return released
    }

    /// Undo: the notice goes, and what it held comes back to be undone rather than go ahead.
    public mutating func undo() -> Held? {
        defer { notice = nil }
        return notice?.held
    }

    /// The notice `id` has shown its time: it goes, if it is still the one showing.
    public mutating func expire(_ id: Notice.ID) -> Held? {
        guard notice?.id == id else { return nil }
        return show(nil)
    }
}
