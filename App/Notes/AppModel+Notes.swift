import AppKit
import ConstellationCore
import Foundation

/// Notes: markdown kept in the app's store, never in the repo, on a card in the pile of the folder
/// it was made for. A new one opens straight into its panel with the caret in the editor.
extension AppModel {
    /// In the focused card's folder, so it lands in that card's pile, else at the root of the given
    /// project, the filtered one or the first.
    func openNote(projectID: UUID? = nil) {
        guard let (project, folder) = noteFolder(projectID: projectID) else {
            notice = "Add a project to keep a note in it."
            return
        }
        let note = Terminal(projectID: project.id, workingDirectory: folder, title: "", note: "")
        terminalsByID[note.id] = note
        save(note)
        // The session's panel goes first, so ⌘W and the rest act on the note in front of it.
        if openedSessionID != nil { closeSession() }
        openTerminalView(note.id)
    }

    private func noteFolder(projectID: UUID?) -> (Project, URL)? {
        if let project = project(projectID) { return (project, project.rootPath) }
        switch focusedItem {
        case .session(let id)?:
            if let session = sessionsByID[id], let project = project(session.projectID) {
                return (project, session.isDraft ? project.rootPath : session.worktreePath)
            }
        case .terminal(let id)?:
            if let terminal = terminalsByID[id], let project = project(terminal.projectID) { return (project, terminal.workingDirectory) }
        case nil:
            break
        }
        return (project(projectFilter) ?? projects.first).map { ($0, $0.rootPath) }
    }

    /// The opened panel's note, if it is one.
    var openedNote: Terminal? {
        openedTerminalID.flatMap { terminalsByID[$0] }.flatMap { $0.isNote ? $0 : nil }
    }

    /// The note's text as its editor has it, saved or not.
    func noteText(of id: UUID) -> String {
        noteEdits[id] ?? terminalsByID[id]?.note ?? ""
    }

    /// What the editor sends as you type: saved once you pause.
    func editNote(_ id: UUID, text: String) {
        guard text != noteText(of: id) else { return }
        noteEdits[id] = text
        noteSaves[id]?.cancel()
        noteSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.commitNote(id)
        }
    }

    /// Puts what the editor holds on the card, titled by its first line, and in the store.
    func commitNote(_ id: UUID) {
        noteSaves.removeValue(forKey: id)?.cancel()
        guard let text = noteEdits.removeValue(forKey: id), var note = terminalsByID[id] else { return }
        note.note = text
        note.title = NoteText.title(of: text) ?? ""
        terminalsByID[id] = note
        save(note)
    }

    /// ⌘W on a note: gone at once, and back with Undo while the notice shows. An empty one just goes.
    func closeNote(_ id: UUID) {
        commitNote(id)
        guard let note = terminalsByID[id] else { return }
        forgetTerminal(id)
        guard NoteText.title(of: note.note ?? "") != nil else { return }
        let text = "Closed \u{201C}\(displayTitle(of: note))\u{201D}."
        showNotice(text, undo: NoticeUndo(undo: { [weak self] in
            guard let self else { return }
            terminalsByID[note.id] = note
            save(note)
            // Once its card is back, so the card is there to draw the ring.
            Task { @MainActor in self.focusedItem = .terminal(note.id) }
        }))
    }

    /// The project's chats a note can go to, most recently active first.
    func noteRecipients(in projectID: UUID) -> [Session] {
        sessionsByID.values
            .filter { $0.projectID == projectID && !$0.isDraft && $0.lifecycle != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Into the chat's composer, after anything already there, and the chat opens for you to read
    /// and send it.
    func sendNote(_ id: UUID, to sessionID: UUID) {
        commitNote(id)
        guard let text = terminalsByID[id]?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let session = sessionsByID[sessionID] else { return }
        updateDraft(sessionID) { draft in
            draft.text = draft.text.isEmpty ? text : draft.text + "\n\n" + text
        }
        clearFront()
        openSession(sessionID)
        composerFocusRequest = sessionID
        notice = "Added the note to the message for \u{201C}\(session.title)\u{201D}. ↵ sends it."
    }

    func copyNote(_ id: UUID) {
        commitNote(id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(noteText(of: id), forType: .string)
    }
}

extension ActionID {
    static let noteNew: ActionID = "note.new"
    static let noteSend: ActionID = "note.send"
}

extension ActionRegistry {
    static var noteActions: [PaletteAction] {
        [
            PaletteAction(
                id: .noteNew, title: "New note", keywords: ["markdown", "text", "write", "scratch", "jot"], systemImage: "note.text", section: .command,
                keys: [KeyBinding("cmd+shift+i")],
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "New note in \($0.name)", argument: $0.id.uuidString, keywords: ["note", $0.name]) }
                },
                perform: { context, argument in
                    context.model.openNote(projectID: argument.flatMap(UUID.init(uuidString:)))
                }
            ),
            PaletteAction(
                id: .noteSend, title: "Send to chat", keywords: ["note", "message", "composer", "session", "agent"], systemImage: "arrow.up.message",
                section: .command,
                isAvailable: { context, argument in
                    guard let note = context.model.openedNote, let id = argument.flatMap(UUID.init(uuidString:)) else { return false }
                    return context.model.noteRecipients(in: note.projectID).contains { $0.id == id }
                },
                unavailableReason: "Open a note first",
                variants: { context in
                    guard let note = context.model.openedNote else { return [] }
                    return context.model.noteRecipients(in: note.projectID).map {
                        ActionVariant(title: "Send note to \($0.title)", argument: $0.id.uuidString, keywords: ["chat", $0.title])
                    }
                },
                perform: { context, argument in
                    guard let note = context.model.openedNote, let id = argument.flatMap(UUID.init(uuidString:)) else { return }
                    context.model.sendNote(note.id, to: id)
                }
            ),
        ]
    }
}
