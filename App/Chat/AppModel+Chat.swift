import AppKit
import ConstellationCore
import ConstellationGit
import ConstellationStore
import Foundation
import UniformTypeIdentifiers

/// What you are typing to one session.
struct ChatDraft: Hashable, Sendable {
    var text = ""
    var attachments: [Attachment] = []

    var isEmpty: Bool {
        text.allSatisfy(\.isWhitespace) && attachments.isEmpty
    }
}

/// The chat composer's intents: sending, the queue, and attachments.
extension AppModel {
    // MARK: Drafts

    func chatDraft(for id: UUID) -> ChatDraft {
        chatDrafts[id] ?? ChatDraft()
    }

    func updateDraft(_ id: UUID, _ change: (inout ChatDraft) -> Void) {
        var draft = chatDraft(for: id)
        change(&draft)
        chatDrafts[id] = draft.isEmpty ? nil : draft
        if sessionsByID[id]?.isDraft == true {
            placeDraftFromPrompt(id)
            saveDraftSoon(id)
        }
    }

    func openInlineComposer(_ id: UUID, typing text: String = "") {
        focusedItem = .session(id)
        if !text.isEmpty { updateDraft(id) { $0.text += text } }
        inlineComposerID = id
    }

    func closeInlineComposer() {
        inlineComposerID = nil
    }

    // MARK: Sending

    /// ↵ sends, queueing while a turn runs; ⌘↵ steers the running turn instead.
    func sendDraft(_ id: UUID, steer: Bool = false) {
        let draft = chatDraft(for: id)
        guard !draft.isEmpty, let session = sessionsByID[id] else { return }
        if session.isDraft { return startDraft(id) }
        let message = UserMessage(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: draft.attachments)
        chatDrafts[id] = nil
        rememberPrompt(message.text, for: session)
        sendMessage(message, to: id, steer: steer)
    }

    /// Answers a pending ask in words, queues behind a running turn, or goes to the provider now.
    func sendMessage(_ message: UserMessage, to id: UUID, steer: Bool = false) {
        guard let session = sessionsByID[id] else { return }
        switch session.sendRoute(steer: steer) {
        case .answerAsk: replyInWords(message, to: id)
        case .queue: enqueue(message, for: id)
        case .steer, .startTurn: deliver(message, to: id)
        }
    }

    /// Sends a message to the provider now, copying attached files into the worktree first. With no
    /// running process, the provider resumes with the message. A session's messages go out one at a
    /// time, in the order sent, each with its own snapshot.
    func deliver(_ message: UserMessage, to id: UUID) {
        guard let session = sessionsByID[id] else { return }
        let git = services.git
        let previous = deliveries[id]
        deliveries[id] = Task { [weak self] in
            await previous?.value
            let message = await Self.staged(message, for: session, git: git)
            await self?.send(message, to: id)
        }
    }

    private func send(_ message: UserMessage, to id: UUID) async {
        guard let session = sessionsByID[id] else { return }
        if let handle = handles[id] {
            // A Codex steer joins the running turn, so there is no checkpoint to snapshot for.
            let steersCodex = session.provider == .codex && session.runState.isTurnRunning
            if !steersCodex { await takeCheckpoint(of: id) }
            do {
                try await handle.send(message)
            } catch {
                if !steersCodex { dropLastCheckpoint(of: id) }
                notice = "Couldn't send: \(error.localizedDescription)"
            }
            await showRefusedSettings(of: handle, for: id)
        } else if processPhase(id) == .launching {
            // Still starting or resuming: the message waits for that turn to end.
            enqueue(message, for: id)
        } else {
            resume(id, message: message)
        }
    }

    /// Puts the pickers back to what the provider still runs with when it refused a change.
    private func showRefusedSettings(of handle: any ProviderSessionHandle, for id: UUID) async {
        guard let adjustable = handle as? any TurnSettingsAdjustable,
              let refusal = await adjustable.takeRefusal() else { return }
        update(id) { $0.turnSettings = refusal.applied }
        notice = refusal.message
    }

    /// Fills in where the agent reads each attachment sent as a path: the file itself when it is in
    /// the worktree, otherwise a copy of the one checked at attach time. If staging fails the agent
    /// gets Constellation's own copy instead.
    nonisolated static func staged(_ message: UserMessage, for session: Session, git: GitService) async -> UserMessage {
        var message = message
        for attachment in message.attachments where !attachment.isInline(for: session.provider) {
            let staged = try? await git.stageAttachment(
                attachment.storedURL, original: attachment.sourceURL, named: attachment.name, id: attachment.id, in: session.worktreePath
            )
            message.agentPaths[attachment.id] = (staged ?? attachment.storedURL).path(percentEncoded: false)
        }
        return message
    }

    // MARK: Queue

    func enqueue(_ message: UserMessage, for id: UUID) {
        queues[id, default: []].append(QueuedMessage(sessionID: id, message: message))
        saveQueue(id)
    }

    /// Sends the oldest queued message, which starts the next turn. The rest wait for that one to end.
    func flushQueue(_ id: UUID) {
        guard var queue = queues[id], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queues[id] = queue.isEmpty ? nil : queue
        saveQueue(id)
        deliver(next.message, to: id)
    }

    func editQueued(_ messageID: UUID, in id: UUID, text: String) {
        guard let index = queues[id]?.firstIndex(where: { $0.id == messageID }) else { return }
        queues[id]?[index].message.text = text
        if queues[id]?[index].message.isEmpty == true { queues[id]?.remove(at: index) }
        saveQueue(id)
    }

    func moveQueued(_ messageID: UUID, in id: UUID, by offset: Int) {
        queues[id]?.move(messageID, by: offset)
        saveQueue(id)
    }

    func removeQueued(_ messageID: UUID, in id: UUID) {
        queues[id]?.remove(messageID)
        saveQueue(id)
    }

    /// Takes a message out of the queue and steers the running turn with it, or sends it now if
    /// no turn is running.
    func steerQueued(_ messageID: UUID, in id: UUID) {
        guard let route = sessionsByID[id]?.sendRoute(steer: true), route != .queue,
              let queued = queues[id]?.remove(messageID) else { return }
        saveQueue(id)
        if route == .answerAsk {
            replyInWords(queued.message, to: id)
        } else {
            deliver(queued.message, to: id)
        }
    }

    /// Written in place, as settings are, so quick edits land in order. The queue is a few rows.
    private func saveQueue(_ id: UUID) {
        if queues[id]?.isEmpty == true { queues[id] = nil }
        do {
            try services.store.saveQueue(queues[id] ?? [], for: id)
        } catch {
            Log.app.error("Saving the queue failed: \(error, privacy: .public)")
        }
    }

    // MARK: Attachments

    /// Copies files into the attachment library and adds them to the session's draft.
    func attach(files urls: [URL], to id: UUID) {
        let library = services.attachments
        Task { [weak self] in
            let results = await Task.detached { urls.map { url in Result { try library.importFile(at: url) } } }.value
            self?.add(results, to: id)
        }
    }

    func attach(imageData data: Data, pathExtension: String, to id: UUID) {
        let library = services.attachments
        Task { [weak self] in
            let result = await Task.detached { Result { try library.importImage(data, pathExtension: pathExtension) } }.value
            self?.add([result], to: id)
        }
    }

    /// Files dropped on a tile go into its inline composer. Folders still add projects, as on the desktop.
    func dropFiles(_ urls: [URL], onto id: UUID) -> Bool {
        for folder in urls where Self.isFolder(folder) { addProject(at: folder) }
        let files = urls.filter { !Self.isFolder($0) }
        guard !files.isEmpty else { return !urls.isEmpty }
        attach(files: files, to: id)
        openInlineComposer(id)
        return true
    }

    /// Files dropped on a composer or session view. A folder can't be attached, so it gets a notice.
    func attachDropped(_ urls: [URL], to id: UUID) {
        let folders = urls.filter(Self.isFolder)
        if let folder = folders.first {
            notice = "\(folder.lastPathComponent) is a folder. Attach the files in it instead."
        }
        let files = urls.filter { !Self.isFolder($0) }
        if !files.isEmpty { attach(files: files, to: id) }
    }

    /// The UTTypes the drop targets accept: files, and images with no file behind them.
    static let droppableTypes: [UTType] = [.fileURL, .image]

    /// Takes a drop of files or of bare image data, such as an image dragged out of a browser.
    /// On a tile (`onTile`) folders add projects and the inline composer opens.
    func acceptDrop(_ providers: [NSItemProvider], onto id: UUID, onTile: Bool) -> Bool {
        let fileType = UTType.fileURL.identifier, imageType = UTType.image.identifier
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        let images = providers.filter { !$0.hasItemConformingToTypeIdentifier(fileType) && $0.hasItemConformingToTypeIdentifier(imageType) }
        guard !files.isEmpty || !images.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor [weak self] in
                    if onTile { _ = self?.dropFiles([url], onto: id) } else { self?.attachDropped([url], to: id) }
                }
            }
        }
        for provider in images {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                let png = data.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let png else {
                        self.notice = "Couldn't read the dropped image"
                        return
                    }
                    self.attach(imageData: png, pathExtension: "png", to: id)
                    if onTile { self.openInlineComposer(id) }
                }
            }
        }
        return true
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func removeAttachment(_ attachmentID: UUID, from id: UUID) {
        updateDraft(id) { $0.attachments.removeAll { $0.id == attachmentID } }
    }

    /// Paperclip: picks files for the session's draft.
    func presentAttachmentPanel(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attach(files: panel.urls, to: id)
    }

    /// ⌘V into a focused composer. Files and image data become attachments; anything else is left
    /// for the text field. Returns whether the paste was taken.
    func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard let id = activeComposerID else { return false }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            attach(files: urls, to: id)
            return true
        }
        if let png = pasteboard.data(forType: .png) {
            attach(imageData: png, pathExtension: "png", to: id)
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            attach(imageData: png, pathExtension: "png", to: id)
            return true
        }
        return false
    }

    private func add(_ results: [Result<Attachment, any Error>], to id: UUID) {
        var problems: [String] = []
        var rejected: [Attachment] = []
        updateDraft(id) { draft in
            for result in results {
                switch result {
                case .success(let attachment):
                    if let reason = AttachmentRules.rejection(of: attachment, joining: draft.attachments) {
                        problems.append(reason)
                        rejected.append(attachment)
                    } else {
                        draft.attachments.append(attachment)
                    }
                case .failure(let error):
                    problems.append(error.localizedDescription)
                }
            }
        }
        for attachment in rejected { services.attachments.remove(attachment) }
        if let first = problems.first { notice = first }
    }
}
