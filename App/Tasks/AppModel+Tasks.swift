import ConstellationCore
import Foundation

/// Tasks: a shell named for one command, a dev server or a test watcher, that runs it when made and
/// again on r. Its card shows the command's output and whether it's running, done or failed.
extension AppModel {
    /// Where a task is, for everything that shows it; nil for anything that isn't a task.
    func taskPhase(of terminal: Terminal) -> TaskPhase? {
        guard terminal.isTask else { return nil }
        return TaskPhase(terminal, run: taskRuns[terminal.id], server: shellServers[terminal.id])
    }

    func suggestedTasks(for project: Project) -> [ProjectTask] {
        ProjectTask.suggestions(in: project.rootPath)
    }

    /// The task an action argument names, "project id|task name".
    func task(from argument: String) -> (ProjectTask, UUID)? {
        let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]), let project = project(id),
              let task = suggestedTasks(for: project).first(where: { $0.name == parts[1] }) else { return nil }
        return (task, id)
    }

    /// The project's task with this command, if one is open, runs again; otherwise a new one starts.
    func runTask(_ task: ProjectTask, in projectID: UUID) {
        guard let project = project(projectID) else { return }
        if let existing = terminalsByID.values.first(where: { $0.projectID == projectID && $0.command == task.command }) {
            focusedItem = .terminal(existing.id)
            return restartTask(existing.id)
        }
        let terminal = Terminal(projectID: project.id, workingDirectory: project.rootPath, title: task.name, command: task.command)
        terminalsByID[terminal.id] = terminal
        save(terminal)
        focusedItem = .terminal(terminal.id)
        restartTask(terminal.id)
    }

    /// Runs the task's command at the shell's next prompt: now if it's idle, after ⌃C if it's still
    /// running, once it starts if it has no shell yet.
    func restartTask(_ id: UUID) {
        guard let terminal = terminalsByID[id], let command = terminal.command else { return }
        // A new run: the last one's result no longer shows.
        taskRuns[id] = .starting
        if !terminalHost.hasShell(id) {
            pendingTaskCommands[id] = command
            startShell(for: terminal)
        } else if terminal.state == .running {
            pendingTaskCommands[id] = command
            terminalHost.send("\u{3}", to: id)
        } else {
            terminalHost.send(command + "\r", to: id)
        }
    }

    func stopTask(_ id: UUID) {
        pendingTaskCommands[id] = nil
        // Stopped before its command started: no command will end to say so.
        if taskRuns[id] == .starting, terminalsByID[id]?.state != .running {
            taskRuns[id] = .ended(code: TaskPhase.interruptCode, at: .now, lines: [])
        } else if taskRuns[id] == .started {
            taskRuns[id] = .stopping
        }
        terminalHost.send("\u{3}", to: id)
    }
}
