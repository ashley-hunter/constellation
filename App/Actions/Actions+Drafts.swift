import ConstellationCore
import Foundation

extension ActionID {
    // Launcher
    static let launcherMove: ActionID = "launcher.move"
    static let launcherOpen: ActionID = "launcher.open"
    static let launcherFolder: ActionID = "launcher.folder"
    static let launcherNewProject: ActionID = "launcher.new-project"
    static let launcherErase: ActionID = "launcher.erase"
    static let launcherClear: ActionID = "launcher.clear"

    // Drafts
    static let draftStart: ActionID = "draft.start"
    static let draftDiscard: ActionID = "draft.discard"
    static let draftWorktree: ActionID = "draft.worktree"
    static let launcherDismiss: ActionID = "launcher.dismiss"
}

/// The empty-state launcher's keys, and acting on a draft session.
extension ActionRegistry {
    /// Ahead of the desktop's own keys, so ↑↓ ↵ and esc work the launcher while it shows.
    static var launcherActions: [PaletteAction] {
        let showing: PaletteAction.Predicate = { context, _ in context.model.launcherTakesKeys }
        let digits = (1...9).map { KeyBinding("opt+\($0)", argument: "\($0)") }
        return [
            PaletteAction(
                id: .launcherMove, title: "Choose a project", section: .navigation,
                keys: [KeyBinding("up", argument: "up"), KeyBinding("down", argument: "down")],
                isAvailable: showing,
                perform: { context, argument in context.model.moveLauncherSelection(by: argument == "up" ? -1 : 1) }
            ),
            PaletteAction(
                id: .launcherOpen, title: "Start a session in the project", section: .navigation,
                keys: [KeyBinding("return")] + digits,
                isAvailable: { context, argument in
                    let model = context.model
                    guard model.launcherTakesKeys else { return false }
                    guard let index = argument.flatMap(Int.init) else { return true }
                    return model.launcherProjects.indices.contains(index - 1)
                },
                perform: { context, argument in
                    let model = context.model
                    if let index = argument.flatMap(Int.init) {
                        model.openFromLauncher(model.launcherProjects[index - 1].id)
                    } else {
                        model.openSelectedLauncherRow()
                    }
                }
            ),
            PaletteAction(
                id: .launcherNewProject, title: "New project…", section: .navigation,
                keys: [KeyBinding("opt+n")],
                isAvailable: showing,
                perform: { context, _ in context.model.runLauncherRow(.newProject) }
            ),
            PaletteAction(
                id: .launcherFolder, title: "Open folder…", section: .navigation,
                keys: [KeyBinding("opt+o")],
                isAvailable: showing,
                perform: { context, _ in context.model.runLauncherRow(.openFolder) }
            ),
            PaletteAction(
                id: .launcherErase, title: "Erase filter", section: .navigation,
                keys: [KeyBinding("delete")],
                isAvailable: { context, _ in context.model.launcherTakesKeys && !context.model.launcher.query.isEmpty },
                perform: { context, _ in context.model.launcher.query.removeLast() }
            ),
            PaletteAction(
                id: .launcherClear, title: "Clear filter", section: .navigation,
                keys: [KeyBinding("escape")],
                isAvailable: { context, _ in context.model.launcherTakesKeys && !context.model.launcher.query.isEmpty },
                perform: { context, _ in context.model.launcher.query = "" }
            ),
            PaletteAction(
                id: .launcherDismiss, title: "Put away", section: .navigation,
                keys: [KeyBinding("escape")],
                isAvailable: { context, _ in
                    let model = context.model
                    return model.launcherTakesKeys && model.launcher.query.isEmpty && model.canDismissLauncher
                },
                perform: { context, _ in context.model.dismissLauncher() }
            ),
        ]
    }

    /// Drafts aren't sessions yet, so these find theirs from the target rather than `context.session`.
    static var draftActions: [PaletteAction] {
        [
            PaletteAction(
                id: .draftStart, title: "Start session", keywords: ["send", "launch", "draft", "first message"],
                systemImage: "paperplane", section: .command,
                isAvailable: { context, _ in
                    guard let id = context.draftID else { return false }
                    return !context.model.chatDraft(for: id).isEmpty
                },
                perform: { context, _ in
                    guard let id = context.draftID else { return }
                    context.model.openSession(id)
                    context.model.startDraft(id)
                }
            ),
            PaletteAction(
                id: .draftWorktree, title: "Switch between a new worktree and the project folder",
                keywords: ["worktree", "project folder", "main checkout", "where it runs", "draft"],
                systemImage: "square.stack", section: .command,
                keys: [KeyBinding("alt+w")],
                isAvailable: { context, _ in
                    guard let id = context.draftID else { return false }
                    return context.model.openedSessionID == id
                },
                perform: { context, _ in
                    guard let id = context.draftID, let session = context.model.sessionsByID[id] else { return }
                    context.model.setDraftWorktree(id, !session.usesWorktree)
                }
            ),
            PaletteAction(
                id: .draftDiscard, title: "Discard draft", keywords: ["delete", "throw away", "new session", "cancel"],
                systemImage: "trash", section: .command,
                isAvailable: { context, _ in context.draftID != nil },
                perform: { context, _ in
                    guard let id = context.draftID else { return }
                    context.model.discardDraft(id)
                }
            ),
        ]
    }
}

extension ActionContext {
    /// The targeted session when it is still a draft.
    var draftID: UUID? {
        sessionID.flatMap { model.sessionsByID[$0]?.isDraft == true ? $0 : nil }
    }
}
