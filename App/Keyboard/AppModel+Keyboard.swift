import ConstellationCore
import Foundation
import SwiftUI

/// Jump hints, and ⌘ spreading a pile.
extension AppModel {
    // MARK: Jumping

    /// The card a digit names: each pile's top card, or the fanned cards.
    func digitTarget(_ digit: String?) -> TileItem? {
        guard let digit else { return nil }
        let labels = digitLabels
        guard let index = labels.firstIndex(of: keyboard.typedDigits + digit) else { return nil }
        return jumpTargets[index]
    }

    /// The ⌘-hold label of every target: single digits for up to ten, two digits for every one beyond.
    var digitLabels: [String] {
        JumpHints.digitLabels(count: jumpTargets.count)
    }

    /// Whether ⌘ and this digit lead somewhere: straight to a target, or to a two-digit label's
    /// first half.
    func acceptsDigit(_ digit: String?) -> Bool {
        guard let digit else { return false }
        let typed = keyboard.typedDigits + digit
        return digitLabels.contains { $0.hasPrefix(typed) }
    }

    /// ⌘ and a digit: jumps when that completes a label, otherwise remembers it as the first half.
    func typeJumpDigit(_ digit: String?, opening: Bool) {
        guard let digit else { return }
        if let item = digitTarget(digit) {
            keyboard.typedDigits = ""
            // A pile of several spreads instead, for the next number to open one of its cards.
            if opening, let id = pileID(of: item), (self.pile(id)?.cards.count ?? 0) > 1 {
                jump(to: item, opening: false)
                spreadAfterJump(to: item)
            } else {
                jump(to: item, opening: opening)
            }
        } else if acceptsDigit(digit) {
            keyboard.typedDigits += digit
        } else {
            keyboard.typedDigits = ""
        }
    }

    /// Focuses a tile, out of any session view, or opens it in split focus.
    func jump(to item: TileItem, opening: Bool) {
        clearFront()
        if item != openedSessionID.map(TileItem.session) { leaveOpenDraft() }
        if opening {
            switch item {
            case .session(let id): openSession(id)
            case .terminal(let id): openTerminalView(id)
            }
            return
        }
        if openedSessionID != nil { openedSessionID = nil }
        focus(item)
    }

    /// Every card ⌘J can badge: each pile's top card, or the fanned cards.
    var hintTargets: [TileItem] {
        geometry.targets
    }

    // MARK: ⌘ on a pile

    /// The cards of the pile ⌘ spread, front first, with the number that picks each: 1 its top
    /// card in the middle of the spread, then round it.
    var commandSpreadHints: [KeyboardController.Hint] {
        guard let id = commandSpreadPile, let pile = self.pile(id) else { return [] }
        return zip(pile.cards, JumpHints.digitLabels(count: pile.cards.count)).map { KeyboardController.Hint(item: $0, label: $1) }
    }

    /// Letting go of ⌘ after ⌘ and a number spread a pile numbers its cards, for one more number to
    /// open one. (Holding ⌘ alone only numbers the piles: their numbers spread them.)
    func commandHintsChanged(_ shown: Bool) {
        if shown {
            return
        } else if let id = commandSpreadPile {
            if !commandSpreadUsed, !isDesktopCovered, let item = focusedItem, pileID(of: item) == id {
                showCommandSpreadHints()
            } else {
                endCommandSpread()
            }
        }
    }

    /// ⌘ and a number on a pile of several spreads it where it sits, its cards numbered once ⌘ is
    /// let go, so one number opens a card; ↵ opens the top one and esc gathers it.
    private func spreadAfterJump(to item: TileItem) {
        guard let id = pileID(of: item), let pile = self.pile(id), pile.cards.count > 1 else { return }
        pileHoverTask?.cancel()
        commandSpreadPile = id
        commandSpreadUsed = false
        withAnimation(.fan) { hoveredPile = id }
        // A quick ⌘ and number never showed the ⌘ badges, so letting go of ⌘ won't number the cards.
        if !keyboard.showsDigitHints { showCommandSpreadHints() }
    }

    /// The spread pile's cards take their numbers, one of which opens its card.
    private func showCommandSpreadHints() {
        keyboard.hintSession = KeyboardController.HintSession(hints: commandSpreadHints, opens: true)
    }

    /// Puts the jump hints away, and gathers a pile ⌘ spread, whose numbers go with them. Wherever
    /// hints are dismissed, so a spread pile is never left out with nothing to pick its cards.
    func endHints() {
        keyboard.hintSession = nil
        endCommandSpread()
    }

    /// Gathers the pile ⌘ spread, once its numbers are done with.
    func endCommandSpread() {
        guard let id = commandSpreadPile else { return }
        commandSpreadPile = nil
        if hoveredPile == id { raise(id) { self.hoveredPile = nil } }
    }

    /// Opens a card of the pile ⌘ spread, leaving the pile spread under the panel, so the panel grows
    /// from where the card is rather than from where it would gather to; the pile gathers once the
    /// panel has gone (see `finishClosing`).
    private func openFromCommandSpread(_ open: () -> Void) {
        let spread = commandSpreadPile
        commandSpreadPile = nil
        open()
        guard let spread, hoveredPile == spread else { return }
        if openedTile != nil {
            gatherAfterClose = spread
        } else {
            raise(spread) { self.hoveredPile = nil }
        }
    }

    func showJumpHints() {
        let targets = hintTargets
        let labels = JumpHints.labels(count: targets.count)
        keyboard.hintSession = KeyboardController.HintSession(
            hints: zip(targets, labels).map { KeyboardController.Hint(item: $0, label: $1) }
        )
    }

    /// A key while ⌘J hints show: letters narrow them, ⇧ opens instead of focusing, anything else cancels.
    func handleHintKey(_ stroke: KeyStroke) -> Bool {
        guard var session = keyboard.hintSession else { return false }
        // ↵ over a spread's numbers opens the card in focus, its top one.
        if stroke == KeyStroke(key: "return"), let item = focusedItem {
            keyboard.hintSession = nil
            openFromCommandSpread { perform(.tileOpen, on: item) }
            return true
        }
        // Letters for ⌘J, numbers for a spread pile's cards.
        guard stroke.key.count == 1, stroke.key.first.map({ $0.isLetter || $0.isNumber }) == true, stroke.modifiers.isSubset(of: .shift) else {
            endHints()
            return stroke.key == "escape" || !stroke.worksWhileEditing
        }
        session.typed += stroke.key
        session.opens = session.opens || stroke.modifiers.contains(.shift)
        switch JumpHints.resolve(session.typed, among: session.hints.map(\.label)) {
        case .complete(let index):
            let hint = session.hints[index]
            keyboard.hintSession = nil
            if session.opens {
                openFromCommandSpread { jump(to: hint.item, opening: true) }
            } else {
                jump(to: hint.item, opening: false)
            }
        case .partial:
            keyboard.hintSession = session
        case .none:
            endHints()
        }
        return true
    }

    // MARK: Blocked sessions

    /// The session that has waited on you longest.
    var oldestBlocked: UUID? {
        sessionsByID.values.filter { $0.runState == .blocked && $0.lifecycle != .archived }
            .min { ($0.nextAsk?.createdAt ?? $0.lastActivityAt) < ($1.nextAsk?.createdAt ?? $1.lastActivityAt) }?.id
    }
}
