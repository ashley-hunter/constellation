import ConstellationCore
import SwiftUI

/// The Piles desktop: which pile peeks or fans, where each pile sits and what you drag, the Needs
/// you lens and unsettling. Core lays it all out (`Piles`, `PilesLayout`);
/// this keeps the state, saves the arrangement and moves focus.
extension AppModel {
    /// Grid: each pile's slot, as JSON: `{"<folder or ~settled>": {"column": 2, "row": 1}}`.
    static let pileSlotsKey = "piles.slots"
    /// Exposé: every pile in order, as JSON: `["<folder>", ..., "~settled"]`.
    static let pileOrderKey = "piles.order"
    /// The card order you dragged each pile into, as JSON: `{"<folder or ~settled>": [<TileItem>]}`.
    static let pileOrdersKey = "piles.cardOrder"

    /// Every shown pile, its cards in the order you dragged them into, the held ones in the order they had.
    var desktopPiles: [Pile] {
        let draft = launcher.launch.map(\.draftID)
        let piles = Piles.list(sessions: visibleSessions.filter { $0.id != draft }, terminals: visibleTerminals)
        return Piles.holding(Piles.ordered(piles, by: pileOrders), to: heldPiles)
    }

    func pile(_ id: Pile.ID) -> Pile? {
        desktopPiles.first { $0.id == id }
    }

    // MARK: Holding a pile still

    /// The pointer went into or out of one of a pile's cards. Leaving the last one lets the pile's
    /// order go after a moment, so moving between its cards (whose exits and entries can arrive in
    /// either order) doesn't.
    func pointer(over card: TileItem, in pile: Pile.ID, inside: Bool) {
        if inside {
            // The pointer is over one pile at a time, whatever exits went missing on the way.
            pointerCards = pointerCards.filter { $0.value == pile }
            pointerCards[card] = pile
            updateHolds()
        } else {
            pointerCards[card] = nil
            releaseHoldTask?.cancel()
            releaseHoldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.updateHolds()
            }
        }
    }

    /// Holds the pile under the pointer and any fanned one, and lets the rest go on the layout
    /// spring, so whatever changed while it was held moves into place. With no animation the release
    /// takes the caller's, so a pile gathering lets its order go in the same move.
    func updateHolds(on animation: Animation? = .layout) {
        releaseHoldTask?.cancel()
        let wanted = Set(pointerCards.values).union([fannedPile].compactMap { $0 })
        let released = heldPiles.keys.filter { !wanted.contains($0) }
        let added = wanted.subtracting(heldPiles.keys)
        guard !released.isEmpty || !added.isEmpty else { return }
        let current = desktopPiles
        for id in added {
            if let pile = current.first(where: { $0.id == id }) { heldPiles[id] = pile.cards }
        }
        guard !released.isEmpty else { return }
        if let animation {
            withAnimation(animation) {
                for id in released { heldPiles[id] = nil }
            }
        } else {
            for id in released { heldPiles[id] = nil }
        }
    }

    /// The screen beside the sidebar that the piles must fit, clear of the mode label at the bottom.
    var pilesBounds: CGRect {
        let left = showsLauncher || !isSidebarShown ? 24 : DesktopGeometry.sidebarClearance
        return CGRect(x: left, y: 20, width: max(canvasWidth - left - DesktopGeometry.trailingMargin, 1), height: max(canvasHeight - 20 - 44, 1))
    }

    var pilesState: PilesState {
        PilesState(front: focusedItem, hovered: hoveredPile, fannedPile: fannedPile, raised: raisedPile, drag: pileDrag)
    }

    func pilesGeometry(state: PilesState) -> DesktopGeometry {
        DesktopGeometry(piles: pilesLayout(desktopPiles, state: state))
    }

    /// `piles` laid out in the arrangement chosen in Settings.
    func pilesLayout(_ piles: [Pile], state: PilesState = PilesState()) -> PilesLayout {
        switch settings.desktopArrangement {
        case .grid:
            let shown = Set(piles.map(\.id))
            // A filtered-out pile keeps its slot for when it shows again.
            let reserved = Set(pileSlots.filter { !shown.contains($0.key) }.values)
            return PilesLayout.place(piles, slots: pileSlots, reserved: reserved, in: pilesBounds, state: state)
        case .expose:
            // A filtered-out pile keeps its place in the order and the rest close up, larger.
            return PilesLayout.place(piles, order: pileOrder, in: pilesBounds, state: state)
        }
    }

    /// The pile a card is in.
    func pileID(of item: TileItem) -> Pile.ID? {
        desktopPiles.first { $0.cards.contains(item) }?.id
    }

    /// A pile is fanned out.
    var isPileFanned: Bool { fannedPile != nil }

    /// The pile spread out right now: fanned by a click or key, or shown while the pointer is on it.
    var spreadPile: Pile.ID? { fannedPile ?? hoveredPile }

    // MARK: Peek and fan

    /// Peeks a pile after a beat of hover, so passing over it doesn't flick it open, and settles it
    /// back almost at once on leaving. Moving between a pile's cards keeps it peeking. Nothing
    /// peeks while something is dragged, and the pointer leaves a pile ⌘ spread as it is until its
    /// numbers are done with (see `endHints`).
    func hoverPile(_ id: Pile.ID, inside: Bool) {
        pileHoverTask?.cancel()
        pileHoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 80))
            guard let self, !Task.isCancelled, !self.isPileFanned, self.pileDrag == nil, self.commandSpreadPile == nil else { return }
            if inside, self.hoveredPile != id {
                withAnimation(.fan) { self.hoveredPile = id }
            } else if !inside, self.hoveredPile == id {
                // Its held order goes in the same move, rather than shuffling it again a moment
                // after it has gathered.
                self.raise(id) {
                    self.hoveredPile = nil
                    self.updateHolds(on: nil)
                }
            }
        }
    }

    /// Spreads a pile of more than one into a row of full cards where it sits, its top card focused.
    func fanPile(_ id: Pile.ID) {
        guard let pile = self.pile(id), pile.cards.count > 1 else { return }
        pileHoverTask?.cancel()
        raisedPile = nil
        // Focus turns the pile's ring, so it moves on the fan's spring too rather than a second one.
        withAnimation(.fan) {
            hoveredPile = nil
            fannedPile = id
            if focusedItem.map(pile.cards.contains) != true { focusedItem = pile.top }
        }
        updateHolds()
    }

    func gatherPile() {
        guard let id = fannedPile else { return }
        raise(id) {
            self.fannedPile = nil
            self.updateHolds(on: nil)
        }
    }

    /// Keeps a pile above the others while `change` sends it back, so it gathers over its
    /// neighbours rather than under them, until its cards have come fully to rest rather than only
    /// looking done, so none drops under a neighbour as it lands.
    func raise(_ id: Pile.ID, on animation: Animation = .fan, _ change: @escaping () -> Void) {
        raisedPile = id
        withAnimation(animation, completionCriteria: .removed) {
            change()
        } completion: { [weak self] in
            if self?.raisedPile == id { self?.raisedPile = nil }
        }
    }

    /// A focus outside the fanned pile gathers it.
    func gatherFans(leavingFor item: TileItem?) {
        guard let fannedPile, let item, let pile = pileID(of: item), pile != fannedPile else { return }
        gatherPile()
    }

    /// A click on the desktop between the piles: gathers a fan, or clears focus.
    func tapPilesBackground() {
        if fannedPile != nil {
            gatherPile()
        } else {
            focus(nil)
        }
    }

    /// A click on a card opens it; hover has already spread its pile to reach the one you want.
    func tapPileCard(_ card: PilesLayout.Card) {
        perform(.tileOpen, on: card.item)
    }

    /// On the fan's spring, as the cards' looks always move on it.
    func toggleLens() {
        withAnimation(.fan) { isLensOn.toggle() }
    }

    // MARK: Moving piles and cards

    /// A pile's label dragged `translation` so far: the pile follows the pointer, nothing peeks.
    func dragPile(_ id: Pile.ID, by translation: CGSize) {
        // In Exposé the Settled tray always comes last.
        if id == .settled, settings.desktopArrangement == .expose { return }
        if pileDrag == nil {
            pileHoverTask?.cancel()
            if fannedPile != nil { gatherPile() }
            if hoveredPile != nil { withAnimation(.fan) { hoveredPile = nil } }
        }
        pileDrag = PileDrag(.pile(id), offset: CGVector(dx: translation.width, dy: translation.height))
    }

    /// Let go. On the grid the pile snaps into the nearest slot, swapping places with any pile
    /// already there; in Exposé it takes the place in the order of the pile it was let go over,
    /// the piles between shifting along one.
    func dropPile(_ id: Pile.ID, by translation: CGSize) {
        guard pileDrag != nil else { return }
        let layout = geometry.piles
        let offset = CGVector(dx: translation.width, dy: translation.height)
        var slots: [Pile.ID: PileSlot] = [:]
        var order: [Pile.ID]?
        switch settings.desktopArrangement {
        case .grid:
            if let slot = layout.dropSlot(of: id, by: offset) { slots = PilesLayout.moving(id, to: slot, in: layout.slots) }
        case .expose:
            if let target = layout.dropTarget(of: id, by: offset) {
                let moved = PilesLayout.moving(id, to: target, in: layout.order)
                if moved != layout.order { order = moved }
            }
        }
        raise(id, on: .layout) {
            self.pileSlots.merge(slots) { $1 }
            if let order { self.pileOrder = order }
            self.pileDrag = nil
        }
        if !slots.isEmpty || order != nil { savePileArrangement() }
    }

    /// A card of a spread pile dragged `translation` so far. A pile spread by hover fans, so it
    /// stays spread while the card is carried across it.
    func dragCard(_ item: TileItem, by translation: CGSize) {
        if pileDrag == nil, let pile = pileID(of: item), fannedPile != pile { fanPile(pile) }
        pileDrag = PileDrag(.card(item), offset: CGVector(dx: translation.width, dy: translation.height))
    }

    /// Let go: the card takes the place of the card it's over, and the pile keeps that order.
    func dropCard(_ item: TileItem, by translation: CGSize) {
        let index = geometry.piles.dropIndex(of: item, by: CGVector(dx: translation.width, dy: translation.height))
        guard let index, let id = pileID(of: item), let pile = self.pile(id) else {
            withAnimation(.fan) { pileDrag = nil }
            return
        }
        var cards = pile.cards.filter { $0 != item }
        cards.insert(item, at: min(index, cards.count))
        withAnimation(.fan) {
            pileOrders[id] = cards
            // A held pile would otherwise keep the order it had before the drop.
            if heldPiles[id] != nil { heldPiles[id] = cards }
            pileDrag = nil
        }
        savePileArrangement()
    }

    // MARK: Saving the arrangement

    /// Keeps the slots or places in the order the layout gave piles that had none, so a new pile
    /// stays where it landed. A pile moved only because its saved slot was off a shrunken grid
    /// isn't saved there, so it goes back once there's room. Waits for the desktop's real size, so a
    /// first layout at the default size doesn't decide where everything goes.
    func rememberPilePlaces(_ layout: PilesLayout) {
        guard hasMeasuredCanvas else { return }
        let slots = layout.slots.filter { pileSlots[$0.key] == nil }
        let order = layout.grid == nil && layout.order != pileOrder ? layout.order : nil
        guard !slots.isEmpty || order != nil else { return }
        pileSlots.merge(slots) { $1 }
        if let order { pileOrder = order }
        savePileArrangement()
    }

    /// Reads where each pile was and the order you gave their cards.
    func restorePileArrangement() {
        func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let text = (try? services.store.setting(key)) ?? nil else { return nil }
            return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
        }
        if let slots = decode(Self.pileSlotsKey, as: [String: PileSlot].self) {
            pileSlots = Dictionary(slots.map { (Pile.ID(key: $0.key), $0.value) }) { first, _ in first }
        }
        if let order = decode(Self.pileOrderKey, as: [String].self) {
            pileOrder = order.map(Pile.ID.init(key:))
        }
        if let orders = decode(Self.pileOrdersKey, as: [String: [TileItem]].self) {
            pileOrders = Dictionary(orders.map { (Pile.ID(key: $0.key), $0.value) }) { first, _ in first }
        }
        forgetGonePiles()
    }

    /// Drops the places and orders of piles that are gone for good: ones no session or terminal,
    /// shown or not, makes any more.
    private func forgetGonePiles() {
        let live = Set(Piles.list(sessions: Array(sessionsByID.values), terminals: Array(terminalsByID.values)).map(\.id))
        pileSlots = pileSlots.filter { live.contains($0.key) }
        pileOrder = pileOrder.filter(live.contains)
        pileOrders = pileOrders.filter { live.contains($0.key) }
    }

    /// Saves every pile's slot, place in the order and card order.
    func savePileArrangement() {
        forgetGonePiles()
        func encode<T: Encodable>(_ value: T) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        saveSetting(Self.pileSlotsKey, encode(Dictionary(uniqueKeysWithValues: pileSlots.map { ($0.key.key, $0.value) })))
        saveSetting(Self.pileOrderKey, encode(pileOrder.map(\.key)))
        saveSetting(Self.pileOrdersKey, encode(Dictionary(uniqueKeysWithValues: pileOrders.map { ($0.key.key, $0.value) })))
    }

    // MARK: Unsettling

    /// Brings a settled, merged or idle session back to its worktree's pile, and gathers the Settled tray.
    func unsettle(_ id: UUID) {
        guard let session = sessionsByID[id], LifecycleRules.isSettled(session) else { return }
        if fannedPile == .settled { gatherPile() }
        // Its pile is raised, so it flies back over the piles it passes rather than under them.
        let home = Piles.list(sessions: [LifecycleRules.apply(.unsettled, to: session)], terminals: []).first?.id
        raise(home ?? .settled, on: .layout) { self.updateLifecycle(id, .unsettled) }
        focusedItem = .session(id)
    }

    // MARK: Focus

    /// The arrows move between piles, landing on each one's top card; in a fan they move
    /// between its cards. Up and down on a focused pile turn it a card at a time, then go on to the
    /// pile above or below once they reach its end.
    func movePileFocus(_ direction: FocusDirection) {
        let current = geometry
        guard let focused = focusedItem, current.tileFrames[focused] != nil else {
            focusedItem = current.targets.first
            return
        }
        // From the piles as they rest, so a turned pile is measured from its own place.
        let rest = pilesGeometry(state: PilesState(fannedPile: fannedPile))
        let from = isPileFanned ? focused : rest.stack(containing: focused)?.first ?? focused
        guard let frame = rest.tileFrames[from] else { return }
        // Under the lens, a lit pile counts by its place at rest, and the card you're on never counts.
        let reachable = isLensOn ? jumpTargets.map { isPileFanned ? $0 : rest.stack(containing: $0)?.first ?? $0 } : rest.targets
        let candidates = Set(reachable).subtracting([from, focused])
        if let next = DesktopGeometry.neighbour(of: frame, in: direction, among: rest.tileFrames.filter { candidates.contains($0.key) }) {
            focusedItem = next
        }
    }
}

extension AppModel {
    /// Piles sway while the desktop is at rest: not while one is spread or dragged, or under a panel.
    func drifts(_ role: PilesLayout.Card.Role) -> Bool {
        settings.cardsDrift && (role == .top || role == .behind) && spreadPile == nil && !isDesktopCovered
    }
}
