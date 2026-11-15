import AppKit
import ConstellationCore
import ConstellationProviders
import Foundation

/// The composer's `/` command menu, `@` file picker and ↑ prompt history.
extension AppModel {
    private static let commandsFreshFor: TimeInterval = 60
    private static let filesFreshFor: TimeInterval = 30
    private static let menuLimit = 8

    // MARK: Menu

    /// The menu for what is being typed at the end of the session's draft, or nil when none is open.
    func composerMenu(for session: Session) -> ComposerMenu? {
        let text = chatDraft(for: session.id).text
        guard let token = ComposerToken.trailing(in: text), composerAssist.dismissedAt[session.id] != text else { return nil }
        let (key, isLoading, items): (String, Bool, [ComposerMenuItem])
        switch token.kind {
        case .command:
            key = "\(session.provider.rawValue)|\(session.worktreePath.path(percentEncoded: false))"
            let loaded = composerAssist.commands[key]
            if loaded?.isFresh(for: Self.commandsFreshFor) != true { loadCommands(for: session, key: key) }
            isLoading = loaded == nil
            items = ranked("c|\(key)|\(token.query)") {
                FuzzyMatch.rank(token.query, loaded?.value ?? [], limit: Self.menuLimit, text: \.name)
                    .map { Self.item(for: $0, provider: session.provider) }
            }
        case .mention:
            key = session.worktreePath.path(percentEncoded: false)
            let loaded = composerAssist.files[key]
            if loaded?.isFresh(for: Self.filesFreshFor) != true { loadFiles(for: session, key: key) }
            isLoading = loaded == nil
            items = ranked("f|\(key)|\(token.query)") {
                FuzzyMatch.rank(token.query, loaded?.value ?? [], limit: Self.menuLimit).map(Self.item(forFile:))
            }
        }
        // A `/path` or `@handle` that matches nothing isn't a menu.
        guard isLoading || !items.isEmpty || token.query.isEmpty else { return nil }
        return ComposerMenu(token: token, items: items, isLoading: isLoading && items.isEmpty)
    }

    /// The session's slash commands as menu rows, loading them when stale. Empty while loading.
    func slashCommandItems(for session: Session) -> [ComposerMenuItem] {
        let key = "\(session.provider.rawValue)|\(session.worktreePath.path(percentEncoded: false))"
        let loaded = composerAssist.commands[key]
        if loaded?.isFresh(for: Self.commandsFreshFor) != true { loadCommands(for: session, key: key) }
        return (loaded?.value ?? []).map { Self.item(for: $0, provider: session.provider) }
    }

    func selectedMenuIndex(for id: UUID, in menu: ComposerMenu) -> Int {
        min(composerAssist.selection[id] ?? 0, max(menu.items.count - 1, 0))
    }

    func moveMenuSelection(_ id: UUID, in menu: ComposerMenu, by offset: Int) {
        guard !menu.items.isEmpty else { return }
        let count = menu.items.count
        composerAssist.selection[id] = (selectedMenuIndex(for: id, in: menu) + offset + count) % count
    }

    /// Puts the chosen command or `@path` in place of what was being typed.
    func acceptMenuItem(_ item: ComposerMenuItem, in menu: ComposerMenu, for id: UUID) {
        let text = menu.token.replacing(in: chatDraft(for: id).text, with: item.insertion)
        updateDraft(id) { $0.text = text }
        composerAssist.selection[id] = nil
        moveComposerCaretToEnd()
    }

    func dismissMenu(for id: UUID) {
        composerAssist.dismissedAt[id] = chatDraft(for: id).text
        composerAssist.selection[id] = nil
    }

    /// Esc closes an open menu and tab accepts its row, before they reach the desktop.
    func handleComposerMenuKey(_ key: ComposerMenuKey) -> Bool {
        guard let id = activeComposerID, let session = sessionsByID[id], let menu = composerMenu(for: session) else { return false }
        switch key {
        case .dismiss:
            dismissMenu(for: id)
        case .accept:
            guard !menu.items.isEmpty else { return false }
            acceptMenuItem(menu.items[selectedMenuIndex(for: id, in: menu)], in: menu, for: id)
        }
        return true
    }

    private func ranked(_ key: String, _ rank: () -> [ComposerMenuItem]) -> [ComposerMenuItem] {
        if let last = composerAssist.lastRanking, last.key == key { return last.items }
        let items = rank()
        composerAssist.lastRanking = (key, items)
        return items
    }

    private static func item(for command: SlashCommand, provider: Provider) -> ComposerMenuItem {
        let badge: String = switch (command.kind, command.scope) {
        case (.builtIn, _), (_, .builtIn): "built-in"
        case (.skill, let scope): "\(scope.rawValue) skill"
        case (.command, let scope): scope.rawValue
        }
        let insertion = command.insertion(for: provider)
        return ComposerMenuItem(
            id: command.id,
            title: insertion.trimmingCharacters(in: .whitespaces),
            detail: command.description,
            badge: badge,
            insertion: insertion
        )
    }

    private static func item(forFile path: String) -> ComposerMenuItem {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        let mention = path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@\(path)"
        return ComposerMenuItem(id: path, title: name, detail: folder, badge: nil, insertion: mention + " ")
    }

    // MARK: Loading

    private func loadCommands(for session: Session, key: String) {
        guard composerAssist.loading.insert(key).inserted else { return }
        let (provider, worktree, codex) = (session.provider, session.worktreePath, services.codex)
        Task { [weak self] in
            let commands: [SlashCommand] = switch provider {
            case .claudeCode: await Task.detached { ClaudeCommandCatalog.commands(repo: worktree) }.value
            case .codex: (try? await codex.skills(in: worktree)) ?? []
            }
            guard let self else { return }
            self.composerAssist.loading.remove(key)
            self.composerAssist.commands[key] = .init(value: commands, loadedAt: Date())
            self.composerAssist.lastRanking = nil
        }
    }

    private func loadFiles(for session: Session, key: String) {
        guard composerAssist.loading.insert(key).inserted else { return }
        let (git, worktree) = (services.git, session.worktreePath)
        Task { [weak self] in
            let files = (try? await git.listFiles(in: worktree)) ?? []
            guard let self else { return }
            self.composerAssist.loading.remove(key)
            self.composerAssist.files[key] = .init(value: files, loadedAt: Date())
            self.composerAssist.lastRanking = nil
        }
    }

    // MARK: Prompt history

    /// ↑ in an empty composer shows the project's last prompt; further ↑ go back, ↓ comes forward
    /// and past the newest empties the composer. Typing over a shown prompt ends the walk.
    func walkPromptHistory(_ id: UUID, older: Bool) -> Bool {
        guard let session = sessionsByID[id] else { return false }
        let text = chatDraft(for: id).text
        var walk: PromptHistoryWalk
        if let current = composerAssist.walks[id], current.current == text {
            walk = current
        } else if older, text.isEmpty {
            walk = PromptHistoryWalk(entries: promptHistory(for: session.projectID))
        } else {
            return false
        }
        let shown = older ? walk.older() : walk.newer()
        // ↑ with no history at all is left to the field.
        if older, shown == nil, walk.index == nil { return false }
        composerAssist.walks[id] = walk.index == nil ? nil : walk
        if shown != nil || !older {
            updateDraft(id) { $0.text = shown ?? "" }
            moveComposerCaretToEnd()
        }
        return true
    }

    /// Adds a sent prompt to its project's history, in memory and in the store.
    func rememberPrompt(_ text: String, for session: Session) {
        guard !text.allSatisfy(\.isWhitespace) else { return }
        let projectID = session.projectID
        composerAssist.history[projectID] = PromptHistory.recording(text, in: promptHistory(for: projectID))
        composerAssist.walks[session.id] = nil
        let store = services.store
        Task.detached { try? store.recordPrompt(text, for: projectID) }
    }

    private func promptHistory(for projectID: UUID) -> [String] {
        if let known = composerAssist.history[projectID] { return known }
        let entries = (try? services.store.promptHistory(for: projectID)) ?? []
        composerAssist.history[projectID] = entries
        return entries
    }

    /// Setting a field's text from code leaves the caret where it was; put it after the new text.
    private func moveComposerCaretToEnd() {
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
        }
    }
}
