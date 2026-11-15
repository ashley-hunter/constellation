import AppKit
import ConstellationCore

/// Moving around the desktop, and the app-wide commands.
extension ActionRegistry {
    static var navigationActions: [PaletteAction] {
        [

            PaletteAction(
                id: .focusMove, title: "Move focus", section: .navigation,
                keys: ["left", "right", "up", "down"].map { KeyBinding($0, argument: $0) },
                isAvailable: { context, argument in
                    context.surface == .desktop && argument.flatMap(FocusDirection.init(name:)) != nil
                },
                perform: { context, argument in
                    guard let direction = argument.flatMap(FocusDirection.init(name:)) else { return }
                    context.model.moveFocus(direction)
                }
            ),
            PaletteAction(
                id: .tileOpen, title: "Open split focus", section: .navigation,
                keys: [KeyBinding("return"), KeyBinding("space")],
                isAvailable: { context, _ in context.surface != .sessionView && context.item != nil },
                perform: { context, _ in
                    switch context.item {
                    case .session(let id)?: context.model.openSession(id)
                    case .terminal(let id)?: context.model.openTerminalView(id)
                    case nil: break
                    }
                }
            ),
            PaletteAction(
                id: .back, title: "Back", section: .navigation,
                // ⌘M too, for an open shell, which keeps esc while a command runs.
                keys: [KeyBinding("escape"), KeyBinding("cmd+m")],
                perform: { context, _ in context.model.goBack() }
            ),
        ]
    }

    static var commandActions: [PaletteAction] {
        [
            PaletteAction(
                id: .sessionNew, title: "New session", keywords: ["start", "agent", "launch", "create"],
                systemImage: "plus", section: .command,
                keys: [KeyBinding("cmd+n")],
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "New session in \($0.name)", argument: $0.id.uuidString, keywords: ["new", $0.name]) }
                },
                perform: { context, argument in
                    let model = context.model
                    let guess = model.newSessionProjectID(for: context.item)
                    if let id = argument.flatMap(UUID.init(uuidString:)) {
                        model.newDraft(in: id)
                    } else if argument == "here" {
                        model.newDraft(in: guess)
                    } else {
                        model.summonLauncher(selecting: guess)
                    }
                }
            ),
            PaletteAction(
                id: .focusNextBlocked, title: "Next that needs you", keywords: ["needs you", "waiting", "ask", "jump", "failed", "unseen", "attention"],
                systemImage: "exclamationmark.circle", section: .command,
                isAvailable: { context, _ in
                    let model = context.model
                    return switch context.surface {
                    case .sessionView: model.openedSessionID.flatMap { model.nextBlocked(after: .session($0)) } != nil
                    case .desktop: !model.attentionItems.isEmpty
                    }
                },
                perform: { context, _ in
                    let model = context.model
                    switch context.surface {
                    case .sessionView: if let id = model.openedSessionID { model.openNextBlocked(after: id) }
                    case .desktop: model.focusAttention(by: 1)
                    }
                }
            ),
            PaletteAction(
                id: .terminalNew, title: "New terminal", keywords: ["shell", "console"], systemImage: "terminal", section: .command,
                keys: [KeyBinding("cmd+t")],
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "New terminal in \($0.name)", argument: $0.id.uuidString, keywords: ["shell", $0.name]) }
                },
                perform: { context, argument in
                    context.model.openTerminal(projectID: argument.flatMap(UUID.init(uuidString:)))
                }
            ),
            PaletteAction(
                id: .browserNew, title: "New browser", keywords: ["web", "page", "preview", "localhost", "url"], systemImage: "globe", section: .command,
                keys: [KeyBinding("cmd+shift+b")],
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "New browser in \($0.name)", argument: $0.id.uuidString, keywords: ["web", $0.name]) }
                },
                perform: { context, argument in
                    context.model.openBrowser(projectID: argument.flatMap(UUID.init(uuidString:)))
                }
            ),
            PaletteAction(
                id: .taskRun, title: "Run task", keywords: ["script", "npm", "make", "dev", "server", "watch", "test"], systemImage: "play.circle",
                section: .command,
                isAvailable: { context, argument in argument.flatMap(context.model.task(from:)) != nil },
                variants: { context in
                    context.model.projects.flatMap { project in
                        context.model.suggestedTasks(for: project).map { task in
                            ActionVariant(title: "Run \(task.name) in \(project.name)", argument: "\(project.id.uuidString)|\(task.name)", keywords: [task.command, project.name])
                        }
                    }
                },
                perform: { context, argument in
                    guard let (task, projectID) = argument.flatMap(context.model.task(from:)) else { return }
                    context.model.runTask(task, in: projectID)
                }
            ),
            PaletteAction(
                id: .taskRestart, title: "Restart task", keywords: ["run", "again", "rerun"], systemImage: "arrow.clockwise",
                section: .command,
                keys: [KeyBinding("cmd+r")],
                isAvailable: { context, _ in context.taskID != nil },
                perform: { context, _ in
                    if let id = context.taskID { context.model.restartTask(id) }
                }
            ),
            PaletteAction(
                id: .taskStop, title: "Stop task", keywords: ["kill", "interrupt", "ctrl-c"], systemImage: "stop.circle",
                section: .command,
                keys: [KeyBinding("cmd+.")],
                isAvailable: { context, _ in context.taskID.flatMap { context.model.terminalsByID[$0] }.flatMap(context.model.taskPhase(of:))?.isActive == true },
                perform: { context, _ in
                    if let id = context.taskID { context.model.stopTask(id) }
                }
            ),
            PaletteAction(
                id: .terminalClose, title: "Close terminal", keywords: ["shell", "quit", "exit"], systemImage: "xmark.square",
                section: .command,
                isAvailable: { context, _ in
                    if case .terminal? = context.item { true } else { false }
                },
                perform: { context, _ in
                    guard case .terminal(let id)? = context.item else { return }
                    context.model.close(.terminal(id))
                }
            ),
            PaletteAction(
                id: .tileClose, title: "Close", keywords: ["archive", "discard", "terminal", "remove"], systemImage: "xmark",
                section: .command,
                keys: [KeyBinding("cmd+w")],
                // Over a sheet ⌘W does nothing. Settings closes itself (SettingsWindow).
                isAvailable: { context, _ in context.model.sheet == nil && context.item != nil },
                perform: { context, _ in
                    guard let item = context.item else { return }
                    context.model.close(item)
                }
            ),
            PaletteAction(
                id: .projectNew, title: "New project…", keywords: ["create", "repository", "repo", "git init", "folder"],
                systemImage: "plus.rectangle.on.folder", section: .command,
                keys: [KeyBinding("cmd+shift+n")],
                perform: { context, _ in context.model.presentProjectFlow(.newProject) }
            ),
            PaletteAction(
                id: .projectAdd, title: "Add project…", keywords: ["open folder", "local folder", "repository", "repo", "new project"],
                systemImage: "folder.badge.plus", section: .command,
                keys: [KeyBinding("cmd+o")],
                perform: { context, _ in context.model.presentProjectFlow(.menu) }
            ),
            PaletteAction(
                id: .showFilter, title: "Show", keywords: ["filter", "only"], systemImage: "line.3.horizontal.decrease",
                section: .command,
                isAvailable: { _, argument in argument.flatMap(ShowFilter.init(rawValue:)) != nil },
                variants: { context in
                    ShowFilter.allCases.filter { $0 != context.model.showFilter }.map {
                        ActionVariant(title: "Show: \($0.title)", argument: $0.rawValue, keywords: ["filter", "show"])
                    }
                },
                perform: { context, argument in
                    guard let filter = argument.flatMap(ShowFilter.init(rawValue:)) else { return }
                    context.model.toggleShowFilter(filter)
                }
            ),
            PaletteAction(
                id: .projectFilter, title: "Show one project", keywords: ["filter", "project", "only"],
                systemImage: "folder", section: .command,
                isAvailable: { context, argument in context.model.project(argument.flatMap(UUID.init(uuidString:))) != nil },
                variants: { context in
                    let model = context.model
                    let all = model.projectFilter.map { [ActionVariant(title: "Show all projects", argument: $0.uuidString, keywords: ["filter"])] } ?? []
                    return all + model.projects.filter { $0.id != model.projectFilter }.map {
                        ActionVariant(title: "Show only \($0.name)", argument: $0.id.uuidString, keywords: ["filter", $0.name])
                    }
                },
                perform: { context, argument in
                    context.model.toggleProjectFilter(argument.flatMap(UUID.init(uuidString:)))
                }
            ),
            PaletteAction(
                id: .projectByNumber, title: "Show project by number", section: .navigation,
                keys: (1...9).map { KeyBinding("ctrl+\($0)", argument: "\($0)") },
                isAvailable: { context, argument in
                    context.surface == .desktop && argument.flatMap(Int.init).map { context.model.projects.indices.contains($0 - 1) } == true
                },
                perform: { context, argument in
                    guard let index = argument.flatMap(Int.init) else { return }
                    context.model.toggleProjectFilter(context.model.projects[index - 1].id)
                }
            ),
            PaletteAction(
                id: .projectShowInFinder, title: "Show project in Finder", keywords: ["folder", "reveal"],
                systemImage: "folder", section: .command,
                isAvailable: { context, argument in context.model.project(argument.flatMap(UUID.init(uuidString:))) != nil },
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "Show \($0.name) in Finder", argument: $0.id.uuidString, keywords: ["finder", $0.name]) }
                },
                perform: { context, argument in
                    guard let project = context.model.project(argument.flatMap(UUID.init(uuidString:))) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                }
            ),
            PaletteAction(
                id: .projectRemove, title: "Remove project…", keywords: ["delete", "forget", "close", "repository"],
                systemImage: "minus.circle", section: .command,
                isAvailable: { context, argument in context.model.project(argument.flatMap(UUID.init(uuidString:))) != nil },
                variants: { context in
                    context.model.projects.map { ActionVariant(title: "Remove \($0.name)…", argument: $0.id.uuidString, keywords: ["remove", $0.name]) }
                },
                perform: { context, argument in
                    guard let id = argument.flatMap(UUID.init(uuidString:)) else { return }
                    context.model.confirmRemoveProject(id)
                }
            ),
            PaletteAction(
                id: .cleanup, title: "Clean up merged work", keywords: ["archive", "merged", "idle", "worktrees", "disk"],
                systemImage: "trash", section: .command,
                perform: { context, _ in context.model.sheet = .cleanup }
            ),
            PaletteAction(
                id: .settings, title: "Settings…", keywords: ["preferences", "options", "config"], systemImage: "gearshape",
                section: .command,
                keys: [KeyBinding("cmd+,")],
                perform: { context, _ in SettingsWindow.shared.show(model: context.model) }
            ),
            PaletteAction(
                id: .palette, title: "Command palette", keywords: ["search", "find", "archived"], section: .navigation,
                keys: [KeyBinding("cmd+k")],
                perform: { context, argument in
                    let model = context.model
                    if case .palette? = model.sheet, argument == nil {
                        model.sheet = nil
                    } else {
                        model.sheet = .palette(argument ?? "")
                    }
                }
            ),
        ]
    }
}

extension FocusDirection {
    init?(name: String) {
        switch name {
        case "left": self = .left
        case "right": self = .right
        case "up": self = .up
        case "down": self = .down
        default: return nil
        }
    }
}
