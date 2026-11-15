import Foundation

/// How much a card wants you, for ordering a pile: the most urgent card goes on top.
public enum PileRank: Int, Comparable, Hashable, Sendable, CaseIterable {
    /// Settled, merged or idle: gathered into the Settled tray.
    case settled
    case seen
    case unseenDone
    case working
    case failed
    case needsYou

    public static func < (lhs: PileRank, rhs: PileRank) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(_ session: Session) {
        // Even put away: a PR that fails or gets changes requested later still wants you.
        if session.pullRequestNeedsYou {
            self = .needsYou
            return
        }
        switch LifecycleRules.presentation(of: session) {
        case .pebble, .faded:
            self = .settled
            return
        case .full, .titleBar, .hidden:
            break
        }
        switch session.runState {
        case .blocked: self = .needsYou
        case .failed: self = .failed
        case .preparing, .working: self = .working
        case .draft: self = .seen
        case .done, .interrupted: self = session.lifecycle == .unseen ? .unseenDone : .seen
        }
    }

    /// A running command counts as working; otherwise a shell is quiet.
    public init(_ terminal: Terminal) {
        self = terminal.state == .running ? .working : .seen
    }

    /// Stays lit under the Needs you lens: needs you, failed or working.
    public var isLit: Bool { self >= .working }
}

/// Related work gathered into one card's footprint: every live session on a worktree and the
/// terminals on it or made from those sessions. Every project's settled, merged and idle sessions
/// gather into the one Settled tray.
public struct Pile: Identifiable, Hashable, Sendable {
    public enum ID: Hashable, Sendable {
        /// Sessions and terminals sharing this folder (a standardised path).
        case worktree(String)
        /// The Settled tray: every project's settled, merged and idle sessions.
        case settled

        /// What its slot and card order are saved under: the folder, or `~settled`, which no
        /// standardised path can be.
        public var key: String {
            switch self {
            case .worktree(let folder): folder
            case .settled: "~settled"
            }
        }

        public init(key: String) {
            self = key == "~settled" ? .settled : .worktree(key)
        }
    }

    public var id: ID
    /// The project its oldest card belongs to, for its colour and for placing it near that
    /// project's other piles. Nil for the Settled tray.
    public var projectID: UUID?
    /// The branch its oldest session is on, empty when none of them says.
    public var branch: String
    /// Top first: most urgent, then a chat before its terminals.
    public var cards: [TileItem]
    public var ranks: [TileItem: PileRank]

    public init(id: ID, projectID: UUID?, branch: String = "", cards: [TileItem], ranks: [TileItem: PileRank] = [:]) {
        self.id = id
        self.projectID = projectID
        self.branch = branch
        self.cards = cards
        self.ranks = ranks
    }

    public var top: TileItem { cards[0] }
    public var topRank: PileRank { ranks[cards[0]] ?? .seen }
    public var isSettled: Bool { id == .settled }

    public func rank(of item: TileItem) -> PileRank { ranks[item] ?? .seen }
}

public enum Piles {
    /// Every pile on the desktop, across every project: oldest first, the Settled tray last. A
    /// pile's place comes from its slot or its saved place in the order (`PilesLayout`), never
    /// from how urgent it is. Archived sessions are left out.
    ///
    /// A terminal joins its session's pile while that session is in a live pile, otherwise the pile
    /// on its folder (or one its folder is inside), otherwise a pile of its own with any other
    /// terminals on the same folder.
    ///
    /// A draft has no worktree yet, so it joins its project's live work: the pile on the project's
    /// main checkout if a session is there, else the pile of the project's most recently active
    /// session, else a pile of its own.
    public static func list(sessions: [Session], terminals: [Terminal]) -> [Pile] {
        var members: [Pile.ID: [Card]] = [:]
        var liveFolder: [UUID: Pile.ID] = [:]
        let shown = sessions.filter { LifecycleRules.presentation(of: $0) != .hidden }
        var projectPile: [UUID: (id: Pile.ID, isMainCheckout: Bool, activity: Date)] = [:]
        for session in shown where !session.isDraft {
            let rank = PileRank(session)
            let id: Pile.ID = rank == .settled ? .settled : .worktree(folder(session.worktreePath))
            members[id, default: []].append(Card(session, rank: rank))
            guard rank != .settled else { continue }
            liveFolder[session.id] = id
            let candidate = (id: id, isMainCheckout: !session.usesWorktree, activity: session.lastActivityAt)
            if let best = projectPile[session.projectID], best.isMainCheckout != candidate.isMainCheckout
                ? best.isMainCheckout : best.activity >= candidate.activity { continue }
            projectPile[session.projectID] = candidate
        }
        // A project's drafts with no live work to join share one pile, the first one's.
        var draftPile: [UUID: Pile.ID] = [:]
        for session in shown where session.isDraft {
            let rank = PileRank(session)
            let own = draftPile[session.projectID] ?? .worktree(folder(session.worktreePath))
            if projectPile[session.projectID] == nil, rank != .settled { draftPile[session.projectID] = own }
            let id: Pile.ID = rank == .settled ? .settled : projectPile[session.projectID]?.id ?? own
            members[id, default: []].append(Card(session, rank: rank))
            if rank != .settled { liveFolder[session.id] = id }
        }
        for terminal in terminals {
            let path = folder(terminal.workingDirectory)
            let id = terminal.sessionID.flatMap { liveFolder[$0] }
                ?? members.keys.filter { $0.contains(path) }.max { $0.depth < $1.depth }
                ?? .worktree(path)
            members[id, default: []].append(Card(terminal))
        }

        let piles = members.map { id, cards in
            let ordered = cards.sorted(by: Card.onTop)
            let byAge = cards.sorted(by: Card.older)
            let pile = Pile(
                id: id,
                projectID: id == .settled ? nil : byAge.first?.projectID,
                branch: id == .settled ? "" : byAge.first { !$0.branch.isEmpty && !$0.isDraft }?.branch ?? "",
                cards: ordered.map(\.item),
                ranks: Dictionary(uniqueKeysWithValues: ordered.map { ($0.item, $0.rank) })
            )
            // A draft that joined older work doesn't move the pile's place.
            let started = cards.contains { !$0.isDraft } ? cards.filter { !$0.isDraft } : cards
            return (pile: pile, since: started.map(\.createdAt).min() ?? .distantPast)
        }
        return piles.sorted { a, b in
            if a.pile.isSettled != b.pile.isSettled { return b.pile.isSettled }
            return (a.since, a.pile.id.key) < (b.since, b.pile.id.key)
        }.map(\.pile)
    }

    /// The piles with each one in `orders` in the order you dragged its cards into. A card that
    /// wasn't there then goes on top when it needs you or has failed, otherwise at the end.
    public static func ordered(_ piles: [Pile], by orders: [Pile.ID: [TileItem]]) -> [Pile] {
        guard !orders.isEmpty else { return piles }
        return piles.map { pile in
            orders[pile.id].map { reordered(pile, by: $0) { _ in false } } ?? pile
        }
    }

    /// The piles with the ones in `held` keeping the card order they had then, so a card that
    /// changes state while you're pointing at or fanning its pile (say, seen because you hovered
    /// it) doesn't slide out from under the pointer. A card that needs you or has failed still
    /// rises to the top.
    public static func holding(_ piles: [Pile], to held: [Pile.ID: [TileItem]]) -> [Pile] {
        guard !held.isEmpty else { return piles }
        return piles.map { pile in
            held[pile.id].map { reordered(pile, by: $0) { pile.rank(of: $0) >= .failed } } ?? pile
        }
    }

    /// `pile`'s cards in `order`. One not in it goes on top when it needs you or has failed and at
    /// the end otherwise; one `rises` picks goes on top too. Each group keeps the pile's own order.
    private static func reordered(_ pile: Pile, by order: [TileItem], rises: (TileItem) -> Bool) -> Pile {
        let index = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        func onTop(_ item: TileItem) -> Bool {
            index[item] == nil ? pile.rank(of: item) >= .failed : rises(item)
        }
        var pile = pile
        pile.cards = pile.cards.enumerated().sorted { a, b in
            let (aTop, bTop) = (onTop(a.element), onTop(b.element))
            if aTop != bTop { return aTop }
            if aTop { return a.offset < b.offset }
            return (index[a.element] ?? .max, a.offset) < (index[b.element] ?? .max, b.offset)
        }.map(\.element)
        return pile
    }

    /// A folder as one string, so the same worktree always gives the same pile.
    public static func folder(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One card's facts for ordering within its pile.
    private struct Card {
        var item: TileItem
        var rank: PileRank
        var isChat: Bool
        var isDraft = false
        var createdAt: Date
        var projectID: UUID
        /// A session's branch; empty for a terminal.
        var branch = ""
        /// Within a rank: chats by latest activity, terminals by age; idle after the rest.
        var order: (Int, Double, String)

        init(_ session: Session, rank: PileRank) {
            item = .session(session.id)
            self.rank = rank
            isChat = true
            isDraft = session.isDraft
            createdAt = session.createdAt
            projectID = session.projectID
            branch = session.branch
            order = (session.lifecycle == .idle ? 1 : 0, -session.lastActivityAt.timeIntervalSinceReferenceDate, session.id.uuidString)
        }

        init(_ terminal: Terminal) {
            item = .terminal(terminal.id)
            rank = PileRank(terminal)
            isChat = false
            createdAt = terminal.createdAt
            projectID = terminal.projectID
            order = (0, terminal.createdAt.timeIntervalSinceReferenceDate, terminal.id.uuidString)
        }

        static func onTop(_ a: Card, _ b: Card) -> Bool {
            if a.rank != b.rank { return a.rank > b.rank }
            if a.isChat != b.isChat { return a.isChat }
            return a.order < b.order
        }

        /// Sessions before terminals and drafts after both, then by age, so a pile takes its
        /// project and branch from the work that started it.
        static func older(_ a: Card, _ b: Card) -> Bool {
            if a.isDraft != b.isDraft { return b.isDraft }
            if a.isChat != b.isChat { return a.isChat }
            return (a.createdAt, a.order.2) < (b.createdAt, b.order.2)
        }
    }
}

extension Pile.ID {
    /// Whether a terminal in `path` works on this pile's folder: the folder itself or inside it.
    func contains(_ path: String) -> Bool {
        guard case .worktree(let folder) = self else { return false }
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The deepest matching folder wins, so a worktree inside the project root takes its own terminals.
    var depth: Int {
        guard case .worktree(let folder) = self else { return 0 }
        return folder.count
    }
}
