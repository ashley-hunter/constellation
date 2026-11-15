import SwiftUI
import AppKit
import ConstellationCore
import Foundation

/// What a notice's Undo puts back, and what goes ahead once the notice has gone without it.
struct NoticeUndo {
    let undo: @MainActor () -> Void
    var commit: (@MainActor () -> Void)?
}

/// Intents only the registered actions needed, for acting on a session without its view open.
extension AppModel {
    /// esc: puts away what is in front (see `surface`): the zoomed image, a sheet, the opened
    /// terminal, the grid's picker, zoom or the grid itself, the session, the launcher's filter or
    /// the launcher, the inline composer; then on the desktop a fanned pile, then focus.
    func goBack() {
        switch surface {
        case .onboarding:
            // Onboarding takes its own keys.
            break
        case .attachment:
            zoomedAttachment = nil
        case .sheet:
            sheet = nil
        case .terminal:
            openedTerminalID = nil
        case .grid(_, let isPicking, let isZoomed):
            if isPicking { endGridPicking() } else if isZoomed { toggleGridZoom() } else { closeGrid() }
        case .session:
            closeSession()
        case .launcher where !launcher.query.isEmpty:
            launcher.query = ""
        case .launcher where canDismissLauncher:
            dismissLauncher()
        case .inlineComposer:
            closeInlineComposer()
        case .launcher, .desktop:
            if fannedPile != nil { gatherPile() } else { focusedItem = nil }
        }
    }

    func currentModelChoice(of session: Session?) -> ModelChoice? {
        guard let session else { return nil }
        return modelChoices(for: session.provider).first { $0.id == session.model }
    }

    /// A new model keeps the effort and fast mode only if it offers them.
    func selectModel(_ choice: ModelChoice, for id: UUID) {
        setTurnSettings(id) { settings in
            settings.model = choice.id
            if let effort = settings.effort, !choice.efforts.contains(effort) { settings.effort = nil }
            if !choice.supportsFastMode { settings.fastMode = false }
        }
    }

    /// ⌘W: closes a terminal, discards a draft or archives a session. An open panel showing the
    /// item closes with it.
    func close(_ item: TileItem) {
        let session: Session? = if case .session(let id) = item { sessionsByID[id] } else { nil }
        switch TileClose.route(item, session: session, draftIsEmpty: session.map { chatDraft(for: $0.id).isEmpty } ?? true) {
        case .closeTerminal(let id)? where terminalsByID[id]?.isNote == true:
            closeNote(id)
        case .closeTerminal(let id)?:
            closeTerminal(id)
        case .discardDraft(let id, let asks)?:
            if asks {
                let alert = NSAlert()
                alert.messageText = "Discard this draft?"
                alert.informativeText = "What you wrote in it is thrown away."
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            discardDraft(id)
        case .archive(let id, let asks)?:
            if asks { confirmArchive(id) } else { archiveWithUndo(id) }
        case nil:
            break
        }
    }

    /// Takes a finished session off the desktop at once and archives it once the notice offering
    /// Undo has gone, however it goes: timed out, or replaced by another notice (a second ⌘W
    /// archives the first straight away), so nothing stays hidden with no Undo. Quitting before
    /// then keeps it.
    func archiveWithUndo(_ id: UUID) {
        guard let session = sessionsByID[id] else { return }
        if grid?.contains(id) == true {
            removeFromGrid(id)
        } else if openedSessionID == id {
            // Making room for the picker, it closes rather than going back to its own view.
            if gridPicking?.base == id { gridPicking = nil }
            goBack()
        }
        if focusedItem == .session(id) { focusedItem = nil }
        withAnimation(.layout) { _ = pendingArchives.insert(id) }
        showNotice("Archived \u{201C}\(session.title)\u{201D}.", undo: NoticeUndo(
            undo: { [weak self] in
                guard let self else { return }
                withAnimation(.layout) { _ = self.pendingArchives.remove(id) }
                // Once its card is back, so the card is there to draw the ring.
                Task { @MainActor in self.focusedItem = .session(id) }
            },
            commit: { [weak self] in
                guard let self, pendingArchives.contains(id) else { return }
                Task {
                    let problems = await self.archive([id], deletesBranches: false)
                    self.pendingArchives.remove(id)
                    if !problems.isEmpty { self.notice = problems.joined(separator: " ") }
                }
            }
        ))
    }

    /// Shows `text` over the desktop, or nothing. With `undo`, its Undo can put back what was done
    /// until the notice goes; then, or as soon as another notice replaces it, `commit` goes ahead.
    func showNotice(_ text: String?, undo: NoticeUndo? = nil) {
        notices.show(text, holding: undo)?.commit?()
        guard undo != nil, let id = notices.notice?.id else { return }
        Task { [weak self] in
            try? await Task.sleep(for: NoticeTiming.shown)
            self?.expireNotice(id)
        }
    }

    /// The notice `id` has had its time: it goes, if it is still the one showing, and what its Undo
    /// held goes ahead.
    func expireNotice(_ id: UUID) {
        notices.expire(id)?.commit?()
    }

    /// Undoes what the showing notice did, if it can.
    func undoNotice() {
        notices.undo()?.undo()
    }

    var canUndoNotice: Bool { notices.notice?.held != nil }

    /// Archiving one session: its worktree goes (never forced) and its transcript stays. Asks first
    /// only while the session is preparing, working or blocked.
    func confirmArchive(_ id: UUID) {
        guard let session = sessionsByID[id] else { return }
        if TileClose.asksBeforeArchiving(session.runState) {
            let alert = NSAlert()
            alert.messageText = "Archive \u{201C}\(session.title)\u{201D}?"
            alert.informativeText = session.usesWorktree
                ? "Its worktree is removed and its transcript kept. A worktree with uncommitted changes stays."
                : "It leaves the desktop. Its transcript is kept."
            alert.addButton(withTitle: "Archive")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            let problems = await archive([id], deletesBranches: false)
            if !problems.isEmpty { notice = problems.joined(separator: " ") }
        }
    }

    /// Fork from the newest message that can be forked from.
    func forkFromLastMessage(_ id: UUID) {
        Task {
            let transcript = await storedTranscript(of: id)
            guard let session = sessionsByID[id] else { return }
            let entry = transcript.entries.last { entry in
                guard case .user = entry, let index = transcript.messageIndex(ofEntry: entry.id) else { return false }
                return transcript.forkCut(atMessage: index, provider: session.provider) != nil
            }
            guard let entry else {
                notice = "\(session.title) has no message to fork from yet."
                return
            }
            fork(session, transcript: transcript, entryID: entry.id)
        }
    }

    /// Opens the session and asks to rewind to just before its newest message.
    func rewindLastMessage(_ id: UUID) {
        Task {
            let transcript = await storedTranscript(of: id)
            guard let session = sessionsByID[id] else { return }
            let entry = transcript.entries.last { entry in
                guard case .user = entry, let index = transcript.messageIndex(ofEntry: entry.id) else { return false }
                return transcript.rewindCut(toMessage: index, provider: session.provider) != nil
            }
            guard let entry else {
                notice = "\(session.title) has no message to rewind to yet."
                return
            }
            openSession(id)
            requestRewind(session, transcript: transcript, entryID: entry.id)
        }
    }

    private func storedTranscript(of id: UUID) async -> Transcript {
        let (store, recorder) = (services.store, services.recorder)
        try? await recorder.flush()
        let events = await Task.detached { (try? store.events(for: id)) ?? [] }.value
        return Transcript(events.map(\.event))
    }
}
