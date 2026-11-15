import ConstellationCore
import Foundation
import SwiftUI

/// Intents for answering: in place on a focused tile, and in the session view.
extension AppModel {
    /// A reply from the reply box. While an ask is pending it answers the ask in words, except a
    /// secret: Codex would take the words as the secret's value, so the secret is declined and the
    /// words go on as a message.
    func replyInWords(_ message: UserMessage, to id: UUID) {
        guard !message.isEmpty, let session = sessionsByID[id] else { return }
        guard let ask = session.nextAsk, case .secret = ask.kind, mcpSecretRequests[ask.id] == nil,
              handles[id] != nil else {
            sendReply(message, to: id)
            return
        }
        answer(ask: ask, with: .secretDeclined)
        deliver(message, to: id)
    }

    func openSession(_ id: UUID) {
        if lastOpenedSessionID != id, sessionsByID[id]?.isDraft != true {
            previousSessionID = lastOpenedSessionID
            lastOpenedSessionID = id
        }
        focusedItem = .session(id)
        // Reopened while it closes, it turns around as it was.
        if openedSessionID != id, presentingTile != .session(id) {
            startedDraftID = nil
            sessionDetail = nil
            sessionPaneTerminalID = nil
        }
        if discardingDraftID == id { discardingDraftID = nil }
        openedSessionID = id
    }

    /// What the opened-tile slot over the desktop shows: the opened terminal, else the opened
    /// session or draft.
    var openedTile: TileItem? {
        if let id = openedTerminalID, terminalsByID[id] != nil { return .terminal(id) }
        if let id = openedSessionID, sessionsByID[id] != nil { return .session(id) }
        return nil
    }

    /// The pane beside it stays until the panel has gone (see `finishClosing`), so the panel shrinks
    /// back at the width it had.
    func closeSession() {
        if let openedSessionID, closeDraft(openedSessionID) { return }
        if let openedSessionID { focusedItem = .session(openedSessionID) }
        openedSessionID = nil
    }

    /// The opened tile's panel has started opening.
    func startPresenting(_ item: TileItem) {
        presentingTile = item
    }

    /// The opened tile's panel has finished closing, or been replaced by another: its card shows
    /// again, the session's pane goes, and a pile left spread under the panel gathers.
    func finishClosing(_ item: TileItem) {
        if presentingTile == item { presentingTile = nil }
        if case .session(let id) = item { finishClosingDraft(id) }
        guard openedTile == nil else { return }
        sessionDetail = nil
        sessionPaneTerminalID = nil
        if let pile = gatherAfterClose {
            gatherAfterClose = nil
            if hoveredPile == pile, !pointerCards.values.contains(pile) { raise(pile) { self.hoveredPile = nil } }
        }
    }

    /// Shows or hides the pane beside the opened session's transcript. With no pane named it
    /// toggles, opening on Preview. The panel widens and the pane fades in on the one spring.
    func toggleSessionDetail(_ pane: SessionDetail? = nil) {
        withAnimation(.present) {
            if let pane, sessionDetail != pane {
                sessionDetail = pane
            } else {
                sessionDetail = sessionDetail == nil ? .preview : nil
            }
        }
    }

    @discardableResult
    func openNextBlocked(after id: UUID) -> Bool {
        guard case .session(let next)? = nextBlocked(after: .session(id)) else { return false }
        // A terminal opened over the session view would hide it.
        clearFront()
        openSession(next)
        return true
    }

    /// The next blocked tile after `item` in reading order, wrapping, never `item` itself.
    func nextBlocked(after item: TileItem?) -> TileItem? {
        let blocked = geometry.orderedItems.filter { session(for: $0)?.runState == .blocked }
        let start = item.flatMap(blocked.firstIndex(of:)).map { $0 + 1 } ?? 0
        return (0..<blocked.count).lazy.map { blocked[(start + $0) % blocked.count] }.first { $0 != item }
    }

    /// The name of the next blocked session, for the session view's Next button.
    func nextBlockedTitle(after id: UUID) -> String? {
        nextBlocked(after: .session(id)).map(title(of:))
    }
}
