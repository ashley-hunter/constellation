import ConstellationCore
import ConstellationMCP
import Foundation
import SwiftUI

/// Terminals: plain shells in a project root, a worktree, or a session's worktree. They have no
/// asks, never recede, and stop when you close them. One made from a session belongs to it
/// (`Terminal.sessionID`): it stacks behind the session's tile and shows in its Terminal pane.
extension AppModel {
    /// ⌘T and New Terminal open one for the focused tile's folder; the project menus
    /// pass a project to open one at its root.
    func openTerminal(projectID: UUID? = nil) {
        if projectID == nil, let id = openedSessionID, sessionsByID[id]?.isDraft == false {
            openTerminal(inSession: id)
            return
        }
        if let project = project(projectID) {
            openTerminal(in: project.rootPath, project: project, sessionID: nil, title: project.name)
            return
        }
        switch focusedItem {
        case .session(let id)?:
            guard let session = sessionsByID[id], let project = project(session.projectID) else { return }
            openTerminal(in: session.worktreePath, project: project, sessionID: session.id, title: session.title)
        case .terminal(let id)?:
            guard let terminal = terminalsByID[id], let project = project(terminal.projectID) else { return }
            openTerminal(in: terminal.workingDirectory, project: project, sessionID: terminal.sessionID, title: terminal.title)
        case nil:
            guard let project = project(projectFilter) ?? projects.first else {
                notice = "Add a project to open a terminal in it."
                return
            }
            openTerminal(in: project.rootPath, project: project, sessionID: nil, title: project.name)
        }
    }

    /// A new terminal in a session's worktree, belonging to the session. Focused on the desktop;
    /// with the session open, it shows in the session's Terminal pane instead.
    func openTerminal(inSession id: UUID) {
        guard let session = sessionsByID[id], let project = project(session.projectID) else { return }
        let isOpen = openedSessionID == id
        let terminal = openTerminal(in: session.worktreePath, project: project, sessionID: id, title: session.title, focus: !isOpen)
        if isOpen {
            sessionPaneTerminalID = terminal.id
            withAnimation(.present) { sessionDetail = .terminal }
        }
    }

    /// Terminals belonging to a session, oldest first.
    func terminals(ownedBy id: UUID) -> [Terminal] {
        terminals.filter { $0.sessionID == id }
    }

    /// What a terminal is called on screen. One a chat owns is "Shell" (or "Shell 2" and so on), so it
    /// never reads as the chat in front of it; a note with no words yet is "Untitled note"; any
    /// other keeps its own title.
    func displayTitle(of terminal: Terminal) -> String {
        if terminal.isNote, terminal.title.isEmpty { return "Untitled note" }
        guard let owner = terminal.sessionID else { return terminal.title }
        let owned = terminals(ownedBy: owner)
        guard owned.count > 1, let index = owned.firstIndex(where: { $0.id == terminal.id }) else { return "Shell" }
        return "Shell \(index + 1)"
    }

    /// The terminal the session's Terminal pane shows: the one picked there, else its oldest,
    /// opening one without moving focus when it has none.
    func paneTerminal(forSession id: UUID) -> Terminal? {
        let owned = terminals(ownedBy: id)
        if let picked = owned.first(where: { $0.id == sessionPaneTerminalID }) ?? owned.first { return picked }
        guard let session = sessionsByID[id], let project = project(session.projectID) else { return nil }
        return openTerminal(in: session.worktreePath, project: project, sessionID: id, title: session.title, focus: false)
    }

    @discardableResult
    private func openTerminal(in directory: URL, project: Project, sessionID: UUID?, title: String, focus: Bool = true) -> Terminal {
        let terminal = Terminal(projectID: project.id, workingDirectory: directory, sessionID: sessionID, title: title)
        terminalsByID[terminal.id] = terminal
        startShell(for: terminal)
        save(terminal)
        if focus { focusedItem = .terminal(terminal.id) }
        return terminal
    }

    func openTerminalView(_ id: UUID) {
        guard terminalsByID[id] != nil else { return }
        focusedItem = .terminal(id)
        openedTerminalID = id
    }

    func closeTerminal(_ id: UUID) {
        terminalHost.close(id)
        browserHost.close(id)
        browserSnapshots[id] = nil
        browserTitleTones[id] = nil
        forgetTerminal(id)
    }

    /// Called as each surface appears. Terminals restored at launch start their shell here.
    func attachTerminal(_ holder: TerminalHolder, to id: UUID) {
        if !terminalHost.hasShell(id), let terminal = terminalsByID[id] { startShell(for: terminal) }
        terminalHost.attach(holder, to: id)
    }

    func startShell(for terminal: Terminal) {
        let id = terminal.id
        let shell = ShellTerminalView()
        shell.onMark = { [weak self] mark in self?.apply(mark, to: id) }
        shell.onLocalServer = { [weak self] url in
            self?.localServers[terminal.projectID] = url
            self?.shellServers[id] = url
        }
        shell.onExit = { [weak self] code in self?.shellExited(id, code: code) }
        shell.onFocus = { [weak self] in
            // Tiles' shells never take the keyboard, and typing in a session's Terminal pane keeps
            // the session focused, so only the opened terminal's shell moves focus.
            guard let self, openedTerminalID == id, focusedItem != .terminal(id) else { return }
            focusedItem = .terminal(id)
        }
        terminalHost.add(shell, for: id)
        if terminal.state != .idle { terminalsByID[id]?.state = .idle }
        // A Keychain read can wait on an access prompt, so it stays off the main actor.
        let (directory, store) = (launchDirectory(for: terminal), services.secrets)
        let port = worktreePort(for: directory, projectID: terminal.projectID)
        // A task's card reads its output and marks as they arrive, so it keeps its own pty.
        let outlivesApp = !terminal.isTask
        Task { [weak shell] in
            let (secrets, tmux) = await Task.detached {
                (Self.secrets(for: terminal, in: store), outlivesApp ? Tmux.launch(for: id) : nil)
            }.value
            shell?.start(ShellLaunch(directory: directory, secrets: secrets, port: port, tmux: tmux))
        }
    }

    /// Shells kept running in tmux by the last run: those whose terminal is gone stop, and the rest
    /// keep their worktree's port, since a server started there may still hold it.
    func adoptSurvivingShells() {
        guard Tmux.isAvailable else { return }
        for (name, port) in Tmux.sessions() {
            guard let terminal = terminalsByID.values.first(where: { Tmux.name(for: $0.id) == name }) else {
                Task.detached { Tmux.run(["kill-session", "-t", "=\(name)"]) }
                continue
            }
            if let port { worktreePorts[Self.pathKey(launchDirectory(for: terminal))] = port }
        }
    }

    /// The port for processes started in a worktree, the same one for every shell, task, agent and
    /// setup script there; nil in the project's main checkout, which keeps its environment as it is.
    func worktreePort(for directory: URL, projectID: UUID) -> Int? {
        guard let root = project(projectID)?.rootPath else { return nil }
        let key = Self.pathKey(directory)
        guard key != Self.pathKey(root) else { return nil }
        if let port = worktreePorts[key] { return port }
        let given = Set(worktreePorts.values)
        let port = WorktreePort.port(for: directory) { given.contains($0) || WorktreePort.isListening($0) }
        worktreePorts[key] = port
        return port
    }

    /// `PORT` and `CONSTELLATION_PORT` for a process in a worktree, none in the main checkout.
    func portEnvironment(in directory: URL, projectID: UUID) -> [String: String] {
        worktreePort(for: directory, projectID: projectID).map(WorktreePort.environment) ?? [:]
    }

    /// The dev server a shell in the session's worktree is running, its pane's own first.
    func server(forSession id: UUID) -> URL? {
        guard let session = sessionsByID[id] else { return nil }
        let worktree = Self.pathKey(session.worktreePath)
        let shells = terminals(ownedBy: id) + terminals.filter { $0.sessionID != id && Self.pathKey($0.workingDirectory) == worktree }
        return shells.lazy.compactMap { self.shellServers[$0.id] }.first
    }

    static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The terminal's folder, or its project root if a worktree has since been removed.
    private func launchDirectory(for terminal: Terminal) -> URL {
        let candidates = [terminal.workingDirectory, project(terminal.projectID)?.rootPath, .homeDirectory].compactMap(\.self)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? .homeDirectory
    }

    /// The project's secrets, overlaid with the session's own for a terminal opened from one.
    private nonisolated static func secrets(for terminal: Terminal, in store: SecretStore) -> [String: String] {
        do {
            if let sessionID = terminal.sessionID {
                return try store.environment(sessionID: sessionID, projectID: terminal.projectID)
            }
            let scope = SecretStore.Scope.project(terminal.projectID)
            var environment: [String: String] = [:]
            for name in try store.names(scope: scope) { environment[name] = try store.value(name: name, scope: scope) }
            return environment
        } catch {
            Log.app.error("Reading secrets for a terminal failed: \(error, privacy: .public)")
            return [:]
        }
    }

    private func apply(_ mark: ShellMark, to id: UUID) {
        // A server is up only while the command that started it runs.
        if mark != .promptStarted, shellServers[id] != nil { shellServers[id] = nil }
        if mark == .promptStarted, let command = pendingTaskCommands.removeValue(forKey: id) {
            // Cleared as the command is typed rather than as it starts: a quick one's output can
            // arrive in the same read as its start.
            terminalHost.clearRecentOutput(of: id)
            terminalHost.send(command + "\r", to: id)
        }
        guard var terminal = terminalsByID[id] else { return }
        if terminal.isTask {
            // What it printed is read as its command ends, for its card.
            let run = TaskRun.after(mark, from: taskRuns[id], awaitingPrompt: pendingTaskCommands[id] != nil,
                                    lines: TaskOutput.failureLines(terminalHost.recentOutput(of: id)))
            if run != taskRuns[id] { taskRuns[id] = run }
        }
        let before = terminal
        terminal.apply(mark)
        guard terminal != before else { return }
        terminalsByID[id] = terminal
        if terminal.lastExitCode != before.lastExitCode { save(terminal) }
    }

    private func shellExited(_ id: UUID, code: Int32?) {
        guard let terminal = terminalsByID[id] else { return }
        terminalHost.close(id)
        forgetTerminal(id)
        if let code, code != 0 { notice = "The shell in \(terminal.title) exited with code \(code)." }
    }

    func forgetTerminal(_ id: UUID) {
        if Tmux.isAvailable { Task.detached { Tmux.kill(id) } }
        terminalsByID[id] = nil
        shellServers[id] = nil
        taskRuns[id] = nil
        pendingTaskCommands[id] = nil
        if focusedItem == .terminal(id) { focusedItem = nil }
        if openedTerminalID == id { openedTerminalID = nil }
        let store = services.store
        Task.detached { try? store.deleteTerminal(id) }
    }

    func save(_ terminal: Terminal) {
        let store = services.store
        Task.detached { try? store.save(terminal) }
    }
}
