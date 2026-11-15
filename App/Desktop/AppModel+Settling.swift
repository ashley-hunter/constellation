import ConstellationCore
import SwiftUI

/// Settle once seen: finished work you've looked at goes into the Settled tray a moment
/// after you move on from it, so the desktop holds mainly live work. Settle and Unsettle move it by hand.
extension AppModel {
    /// The pointer went onto or off a tile.
    func noteHover(on item: TileItem, hovering: Bool) {
        if hovering { hoveredItems.insert(item) } else { hoveredItems.remove(item) }
        reconsiderSettling()
    }

    /// Starts the grace for every seen, done session you're no longer on, and calls it off for the
    /// ones you've come back to. You're on a session while it's focused, under the pointer, open in
    /// its panel, or in the pile that's fanned out.
    func reconsiderSettling() {
        let candidates = sessionsByID.values.filter { $0.runState == .done && $0.lifecycle == .seen }
        let attended = attendedItems(among: candidates)
        for session in candidates where !attended.contains(.session(session.id)) {
            guard settleTasks[session.id] == nil else { continue }
            let id = session.id
            settleTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: LifecycleRules.settleGrace)
                guard let self, !Task.isCancelled else { return }
                self.settleTasks[id] = nil
                guard !self.attendedItems(among: self.sessionsByID[id].map { [$0] } ?? []).contains(.session(id)) else { return }
                // The tray is raised, so the card flies to it over the piles in between.
                self.raise(.settled, on: .layout) { self.updateLifecycle(id, .movedOn) }
                // It leaves from under the pointer, which may not report leaving.
                self.hoveredItems.remove(.session(id))
            }
        }
        let waiting = Set(candidates.filter { !attended.contains(.session($0.id)) }.map(\.id))
        for id in settleTasks.keys where !waiting.contains(id) {
            settleTasks.removeValue(forKey: id)?.cancel()
        }
    }

    private func attendedItems(among sessions: [Session]) -> Set<TileItem> {
        var items = hoveredItems
        if let focusedItem { items.insert(focusedItem) }
        if let openedSessionID { items.insert(.session(openedSessionID)) }
        guard !sessions.isEmpty, let fannedPile, let pile = pile(fannedPile) else { return items }
        items.formUnion(pile.cards)
        return items
    }

    /// Settles every seen, done session at launch: you'd moved on from them when you quit.
    func settleSeenWorkAtLaunch() {
        for id in sessionsByID.keys {
            updateLifecycle(id, .movedOn)
        }
    }

    /// Puts finished work into the Settled tray now.
    func settle(_ id: UUID) {
        guard let session = sessionsByID[id], LifecycleRules.canSettle(session) else { return }
        settleTasks.removeValue(forKey: id)?.cancel()
        if fannedPile.map({ pile in pileID(of: .session(id)) == pile }) == true { gatherPile() }
        raise(.settled, on: .layout) { self.updateLifecycle(id, .settled) }
        hoveredItems.remove(.session(id))
    }
}
