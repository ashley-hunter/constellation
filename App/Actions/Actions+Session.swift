import AppKit
import ConstellationCore

/// Actions on one session: the focused tile, the open session view, or the tile a menu
/// was opened on.
extension ActionRegistry {
    static var sessionActions: [PaletteAction] {
        askActions + gitActions + branchingActions + turnSettingActions + runActions + fileActions
    }

    private static var askActions: [PaletteAction] {
        // Plain letters type, so answers take ⌥.
        // Typed as String: inferred from `argument` they'd be optional and bind "alt+Optional("y")".
        let answerKeys = ["y", "n", "s"].map { (key: String) in KeyBinding("alt+\(key)", argument: key) } + [KeyBinding("alt+shift+a", argument: "⇧A")]
            + (1...9).map { KeyBinding("alt+\($0)", argument: "\($0)") }
        return [
            PaletteAction(
                id: .askAnswer, title: "Answer", keywords: ["allow", "deny", "approve", "reply"],
                systemImage: "checkmark.bubble", section: .session,
                keys: answerKeys,
                isAvailable: { context, key in
                    guard let key else { return false }
                    return context.session?.nextAsk?.choices.contains { $0.key == key } == true
                },
                variants: { context in
                    (context.session?.nextAsk?.choices ?? []).map {
                        ActionVariant(title: "Answer: \($0.label)", argument: $0.key, keywords: ["answer", "ask"])
                    }
                },
                expandsInPalette: true,
                perform: { context, key in
                    guard let ask = context.session?.nextAsk, let choice = ask.choices.first(where: { $0.key == key }) else { return }
                    context.model.answer(ask: ask, with: choice.answer)
                }
            ),
            PaletteAction(
                id: .askOpen, title: "Answer…", keywords: ["question", "ask", "reply", "pending"],
                systemImage: "questionmark.bubble", section: .session,
                isAvailable: { context, _ in context.session?.nextAsk != nil && context.surface != .sessionView },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.openSession(id)
                }
            ),
        ]
    }

    private static var gitActions: [PaletteAction] {
        GitAction.allCases.map { action in
            let (id, keywords, key): (ActionID, [String], String?) = switch action {
            case .commit: (.gitCommit, ["git", "save", "changes"], "cmd+shift+c")
            case .push: (.gitPush, ["git", "upload", "remote"], "cmd+shift+u")
            case .pullRequest: (.gitPullRequest, ["git", "pr", "github", "pull request", "review"], "cmd+shift+r")
            case .merge: (.gitMerge, ["git", "merge", "land", "main", "local"], nil)
            }
            return PaletteAction(
                id: id, title: action.title, keywords: keywords, systemImage: action.systemImage,
                label: { context in context.session.map(action.title(for:)) ?? action.title },
                section: .session,
                keys: key.map { [KeyBinding($0)] } ?? [],
                // Only a worktree's branch has a base to land on.
                isAvailable: { context, _ in action != .merge || context.session?.usesWorktree == true },
                perform: { context, _ in
                    guard let sessionID = context.sessionID else { return }
                    context.model.openGitSheet(action, for: sessionID)
                }
            )
        }
    }

    private static var branchingActions: [PaletteAction] {
        [
            PaletteAction(
                id: .sessionFork, title: "Fork from the last message", keywords: ["fork", "branch", "copy", "duplicate"],
                systemImage: "arrow.triangle.branch", section: .session,
                isAvailable: { context, _ in context.session.map(context.model.canBranch) ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.forkFromLastMessage(id)
                }
            ),
            PaletteAction(
                id: .sessionRewind, title: "Rewind the last message…", keywords: ["rewind", "undo", "back", "rollback"],
                systemImage: "arrow.uturn.backward", section: .session,
                isAvailable: { context, _ in context.session.map(context.model.canBranch) ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.rewindLastMessage(id)
                }
            ),
            PaletteAction(
                id: .sessionRename, title: "Rename…", keywords: ["title", "name"], systemImage: "pencil", section: .session,
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.promptRenameSession(id)
                }
            ),
            PaletteAction(
                id: .sessionRenameWorktree, title: "Rename worktree…", keywords: ["worktree", "pile", "name", "label"],
                systemImage: "pencil", section: .session,
                isAvailable: { context, _ in context.session?.usesWorktree == true },
                perform: { context, _ in
                    guard let session = context.session, let folder = context.model.worktreeFolder(of: session) else { return }
                    context.model.promptRenameWorktree(folder)
                }
            ),
        ]
    }

    private static var turnSettingActions: [PaletteAction] {
        [
            PaletteAction(
                id: .sessionModel, title: "Change model", keywords: ["model", "switch"], systemImage: "cpu", section: .session,
                isAvailable: { context, argument in
                    guard let session = context.session else { return false }
                    return argument.map { model in context.model.modelChoices(for: session.provider).contains { $0.id == model } } ?? true
                },
                variants: { context in
                    guard let session = context.session else { return [] }
                    return context.model.modelChoices(for: session.provider).filter { $0.id != session.model }.map {
                        ActionVariant(title: "Model: \($0.title)", argument: $0.id, keywords: ["model", "switch"])
                    }
                },
                perform: { context, argument in
                    guard let session = context.session else { return }
                    let choices = context.model.modelChoices(for: session.provider)
                    if let choice = choices.first(where: { $0.id == argument }) {
                        context.model.selectModel(choice, for: session.id)
                    } else {
                        // No model named: the palette opens on the model rows.
                        context.model.sheet = .palette(">model ")
                    }
                }
            ),
            PaletteAction(
                id: .sessionEffort, title: "Change effort", keywords: ["effort", "reasoning", "thinking"],
                systemImage: "brain", section: .session,
                isAvailable: { context, argument in
                    guard let efforts = context.model.currentModelChoice(of: context.session)?.efforts, !efforts.isEmpty else { return false }
                    return argument.map { $0 == "default" || efforts.contains($0) } ?? true
                },
                variants: { context in
                    guard let session = context.session, let choice = context.model.currentModelChoice(of: session) else { return [] }
                    let rows = choice.efforts.filter { $0 != session.effort }.map {
                        ActionVariant(title: "Effort: \($0)", argument: $0, keywords: ["effort", "reasoning"])
                    }
                    return session.effort == nil ? rows : [ActionVariant(title: "Effort: default", argument: "default", keywords: ["effort"])] + rows
                },
                perform: { context, argument in
                    guard let id = context.sessionID else { return }
                    guard let argument else {
                        context.model.sheet = .palette(">effort ")
                        return
                    }
                    context.model.setTurnSettings(id) { $0.effort = argument == "default" ? nil : argument }
                }
            ),
            PaletteAction(
                id: .sessionPermissionMode, title: "Change permission mode", keywords: ["permissions", "approve", "ask", "bypass"],
                systemImage: "lock.shield", section: .session,
                variants: { context in
                    PermissionMode.allCases.filter { $0 != context.session?.permissionMode }.map {
                        ActionVariant(title: "Permissions: \($0.title)", argument: $0.rawValue, keywords: ["permission", "mode"])
                    }
                },
                perform: { context, argument in
                    guard let id = context.sessionID else { return }
                    guard let mode = argument.flatMap(PermissionMode.init(rawValue:)) else {
                        context.model.sheet = .palette(">permissions ")
                        return
                    }
                    context.model.setTurnSettings(id) { $0.permissionMode = mode }
                }
            ),
            PaletteAction(
                id: .sessionFastMode, title: "Fast mode", keywords: ["fast", "priority", "toggle"],
                systemImage: "hare",
                label: { context in context.session?.fastMode == true ? "Turn fast mode off" : "Turn fast mode on" },
                section: .session,
                isAvailable: { context, _ in context.model.currentModelChoice(of: context.session)?.supportsFastMode == true },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.setTurnSettings(id) { $0.fastMode.toggle() }
                }
            ),
        ]
    }

    private static var runActions: [PaletteAction] {
        [
            PaletteAction(
                id: .sessionInterrupt, title: "Interrupt", keywords: ["cancel", "halt", "pause", "turn"], systemImage: "pause.circle",
                section: .session,
                keys: [KeyBinding("cmd+.")],
                isAvailable: { context, _ in
                    guard let id = context.sessionID else { return false }
                    return context.model.canInterrupt(id)
                },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.interrupt(id)
                }
            ),
            PaletteAction(
                id: .sessionStop, title: "Stop", keywords: ["stop", "kill", "end", "interrupt"], systemImage: "stop.circle",
                section: .session,
                // ⌘⇧. as well, which reaches the app while the composer has the keys.
                keys: [KeyBinding("cmd+delete"), KeyBinding("cmd+shift+.")],
                isAvailable: { context, _ in
                    guard let id = context.sessionID else { return false }
                    return context.model.processPhase(id) != .none
                },
                perform: { context, _ in
                    guard let id = context.sessionID, let title = context.session?.title else { return }
                    context.model.stop(id)
                    // Stopping is one key, so say so; Resume brings it back.
                    context.model.notice = "Stopped \u{201C}\(title)\u{201D}. ⌘R resumes it."
                }
            ),
            PaletteAction(
                id: .sessionRetry, title: "Retry", keywords: ["again", "rerun", "failed"], systemImage: "arrow.clockwise",
                section: .session,
                keys: [KeyBinding("cmd+r")],
                isAvailable: { context, _ in
                    if case .failed? = context.session?.runState { true } else { false }
                },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.retry(id)
                }
            ),
            PaletteAction(
                id: .sessionResume, title: "Resume", keywords: ["continue", "restart", "interrupted"], systemImage: "play.circle",
                section: .session,
                keys: [KeyBinding("cmd+r")],
                isAvailable: { context, _ in context.sessionID.map(context.model.canResume) ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.resume(id)
                }
            ),
            PaletteAction(
                id: .sessionArchive, title: "Archive…", keywords: ["clean up", "remove", "close", "done"], systemImage: "archivebox",
                section: .session,
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.confirmArchive(id)
                }
            ),
        ]
    }

    private static var fileActions: [PaletteAction] {
        [
            PaletteAction(
                id: .sessionOpenInEditor, title: "Open in editor", keywords: ["editor", "code", "cursor", "vs code", "zed", "xcode", "finder"],
                systemImage: "arrow.up.forward.app",
                label: { context in "Open in \(context.model.settings.preferredEditor.title)" },
                section: .session,
                keys: [KeyBinding("cmd+shift+o")],
                variants: { context in
                    let preferred = context.model.settings.preferredEditor
                    return Editor.installed.filter { $0 != preferred }.map {
                        ActionVariant(title: "Open in \($0.title)", argument: $0.rawValue, keywords: ["editor", "open"])
                    }
                },
                perform: { context, argument in
                    guard let id = context.sessionID else { return }
                    context.model.openInEditor(id, editor: argument.flatMap(Editor.init(rawValue:)))
                }
            ),
            PaletteAction(
                id: .sessionTerminal, title: "Open terminal", keywords: ["shell", "worktree", "console"], systemImage: "terminal",
                section: .session,
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.openTerminal(inSession: id)
                }
            ),
            PaletteAction(
                id: .sessionDetail, title: "Show preview, diff and terminal",
                keywords: ["pane", "side", "split", "preview", "diff", "terminal", "shell", "hide"], systemImage: "sidebar.right",
                label: { context in
                    context.model.sessionDetail == nil ? "Show preview, diff and terminal" : "Hide preview, diff and terminal"
                },
                section: .session,
                // ⌘⌥1-4 go straight to Preview, Diff, Terminal or the PR.
                keys: {
                    let tabs = SessionDetail.allCases.enumerated().map { KeyBinding("cmd+alt+\($0.offset + 1)", argument: $0.element.rawValue) }
                    return [KeyBinding("cmd+shift+d")] + tabs
                }(),
                isAvailable: { context, argument in
                    guard context.surface == .sessionView else { return false }
                    guard let argument else { return true }
                    let detail = SessionDetail(rawValue: argument)
                    return detail != nil && (detail != .pullRequest || context.session?.pullRequest != nil)
                },
                variants: { _ in
                    SessionDetail.allCases.map { ActionVariant(title: "Show \($0 == .pullRequest ? $0.title : $0.title.lowercased())", argument: $0.rawValue, keywords: ["pane", $0.title]) }
                },
                perform: { context, argument in
                    context.model.toggleSessionDetail(argument.flatMap(SessionDetail.init(rawValue:)))
                }
            ),
            PaletteAction(
                id: .sessionPrevious, title: "Previous chat", keywords: ["back", "last", "switch", "toggle", "recent"],
                systemImage: "arrow.uturn.backward", section: .navigation,
                // ⌃⇥ flips between the last two chats, from the desktop or inside one, as ⌘⇥ does apps.
                keys: [KeyBinding("ctrl+tab")],
                isAvailable: { context, _ in
                    let model = context.model
                    guard let id = model.previousSessionID, model.sessionsByID[id] != nil else { return false }
                    return model.openedSessionID != id
                },
                perform: { context, _ in
                    let model = context.model
                    guard let id = model.previousSessionID else { return }
                    model.clearFront()
                    model.openSession(id)
                }
            ),
            PaletteAction(
                id: .sessionCopyBranch, title: "Copy branch name", keywords: ["git", "clipboard"], systemImage: "doc.on.doc",
                section: .session,
                isAvailable: { context, _ in context.session?.branch.isEmpty == false },
                perform: { context, _ in
                    guard let branch = context.session?.branch else { return }
                    copyToPasteboard(branch)
                }
            ),
            PaletteAction(
                id: .sessionCopyPath, title: "Copy worktree path", keywords: ["folder", "clipboard"], systemImage: "doc.on.doc",
                section: .session,
                perform: { context, _ in
                    guard let path = context.session?.worktreePath.path(percentEncoded: false) else { return }
                    copyToPasteboard(path)
                }
            ),
        ]
    }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
