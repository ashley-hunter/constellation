import ConstellationCore
import Foundation

/// Moving through only the work that wants you: waiting on you, then failed, then finished and not
/// yet seen, each in reading order. ⌥Tab steps through it, ⌘ numbers it first, and the Needs you
/// lens keeps the other keys to it too.
extension AppModel {
    /// How much each card wants you, worked out once from every pile.
    var pileRanks: [TileItem: PileRank] {
        var ranks: [TileItem: PileRank] = [:]
        for pile in desktopPiles {
            for item in pile.cards { ranks[item] = pile.rank(of: item) }
        }
        return ranks
    }

    /// Everything that needs your attention, most urgent first: one entry per pile, its top card
    /// (where the most urgent card always sits), so each gets one number and ⌥Tab doesn't stop
    /// twice on the same pile.
    var attentionItems: [TileItem] {
        let ranks = pileRanks
        let geometry = geometry
        var seen = Set<TileItem>()
        var ranked: [(item: TileItem, rank: PileRank, order: Int)] = []
        for (order, item) in geometry.orderedItems.enumerated() {
            // A pile wants you as much as its keenest card, whichever card is on top.
            let stack = geometry.stack(containing: item) ?? [item]
            guard let rank = stack.compactMap({ ranks[$0] ?? session(for: $0).map(PileRank.init) }).max(),
                  [.needsYou, .failed, .unseenDone].contains(rank) else { continue }
            let top = stack.first ?? item
            guard seen.insert(top).inserted else { continue }
            ranked.append((top, rank, order))
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.order < $1.order }.map(\.item)
    }

    /// ⌥Tab and ⌥⇧Tab: the next or previous thing that needs you, wrapping round. Keeps its place
    /// when the card it was on drops out of the list (seen once you've looked at it).
    func focusAttention(by step: Int) {
        let items = attentionItems
        guard !items.isEmpty else { return }
        let next: Int
        if let current = focusedItem, let index = items.firstIndex(of: current) {
            next = (index + step + items.count) % items.count
        } else if let cursor = attentionCursor, focusedItem == cursor.item {
            // The card left the list, so whatever was after it now sits at its old place.
            next = step > 0 ? cursor.index % items.count : (cursor.index - 1 + items.count) % items.count
        } else {
            next = step > 0 ? 0 : items.count - 1
        }
        attentionCursor = (items[next], next)
        jump(to: items[next], opening: false)
    }

    /// What the arrows and ⌘ numbers reach: everything, or under the Needs you lens only what's lit
    /// (a pile at rest by its top, cards in a fan each on their own). What needs you comes first, so
    /// ⌘1 is always the most urgent.
    var jumpTargets: [TileItem] {
        let geometry = geometry
        guard isLensOn else {
            let urgent = attentionItems.filter(geometry.targets.contains)
            return urgent + geometry.targets.filter { !urgent.contains($0) }
        }
        let ranks = pileRanks
        func lit(_ item: TileItem) -> Bool { ranks[item]?.isLit == true }
        if isPileFanned { return geometry.targets.filter(lit) }
        return geometry.targets.filter { item in
            geometry.stack(containing: item)?.contains(where: lit) ?? lit(item)
        }
    }
}
