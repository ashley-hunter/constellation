import ConstellationCore
import Foundation

// MARK: - The action registry
//
// Every command in the app is a `PaletteAction`, registered once in `ActionRegistry.all`. The menu
// bar, tile menus, buttons, desktop keys and the ⌘K palette all run actions through
// `AppModel.perform(_:on:argument:via:)`, so an action registered here shows up in the palette and
// can be bound to a key with nothing else to wire.
//
// An action has:
// - `id`: a stable dotted name ("git.commit"). keys.conf binds keys to it, recents are stored by it,
//   so never rename one. Add a constant to `ActionID` for each.
// - `title`, `keywords` and `systemImage` for the palette. Keywords are matched fuzzily like the title.
//   `label(context)` can replace the title where it depends on the target ("Open in Cursor").
// - `section`: `.session` acts on a session (the focused or opened one, or the tile a menu
//   was opened on) and is listed first in the palette; `.command` is app-wide; `.navigation` is for
//   keys only and never listed (moving focus, esc).
// - `keys`: default key bindings. A binding can carry an argument
//   ("ctrl+1" → project.byNumber 1). Several actions may share a key: a key runs the first
//   available one, in registry order. keys.conf adds to and removes from these (App/Keyboard, and
//   the Keymap in Core).
// - `isAvailable(context, argument)`: whether it can run now. Unavailable actions are greyed out in
//   menus, listed dimmed in the palette only when searched for by title (with `unavailableReason`),
//   and let their key fall through.
// - `variants(context)`: palette rows for an action that takes an argument (one per project, model,
//   filter...). They show once something is typed, or always with `expandsInPalette`. Until
//   then an action that can't run without an argument shows one row that narrows to its variants.
// - `perform(context, argument)`: does it. The argument is a plain string so keys.conf can pass one.
//
// To add actions: write a `static var yourActions: [PaletteAction]` in an extension (see
// Actions+Session.swift), append it in `ActionRegistry.all`, and add its ids to `ActionID`.
// In a view: `ActionButton(.gitCommit, on: .session(id))`, or `model.perform(.gitCommit, on: ...)`.

/// A registered action's stable name, as keys.conf and the stored palette recents spell it.
struct ActionID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }

    var description: String { rawValue }
}

/// How an action was asked for. Keys are pickier than the palette or a menu about what is in front.
enum ActionTrigger: Sendable {
    case key, menu, palette
}

/// What an action acts on. `item` is the tile it targets: the one a menu was opened on, or else the
/// opened session or the focused tile.
@MainActor
struct ActionContext {
    /// Where the keyboard is, which changes what some keys mean.
    enum Surface: Equatable {
        case desktop, sessionView
    }

    let model: AppModel
    let item: TileItem?
    let trigger: ActionTrigger

    var sessionID: UUID? {
        if case .session(let id)? = item { id } else { nil }
    }

    /// The targeted terminal, when it's a task.
    var taskID: UUID? {
        guard case .terminal(let id)? = item, model.terminalsByID[id]?.isTask == true else { return nil }
        return id
    }

    /// The targeted session, when it is on the desktop (not archived) and launched (not a draft).
    var session: Session? {
        sessionID.flatMap { model.sessionsByID[$0] }.flatMap { $0.lifecycle == .archived || $0.isDraft ? nil : $0 }
    }

    var surface: Surface {
        if model.openedSessionID != nil { return .sessionView }
        return .desktop
    }
}

/// One palette row of an action that takes an argument.
struct ActionVariant {
    let title: String
    let argument: String
    var keywords: [String] = []
}

/// A command the menus, keys and palette share. See the top of this file.
struct PaletteAction: Identifiable {
    enum Section {
        case session, command, navigation
    }

    typealias Predicate = @MainActor (ActionContext, String?) -> Bool

    let id: ActionID
    let title: String
    var keywords: [String] = []
    var systemImage: String?
    var label: (@MainActor (ActionContext) -> String)?
    let section: Section
    var keys: [KeyBinding] = []
    var isAvailable: Predicate = { _, _ in true }
    /// Why the palette shows it dimmed when you search for it and it can't run.
    var unavailableReason: String?
    var variants: (@MainActor (ActionContext) -> [ActionVariant])?
    var expandsInPalette = false
    let perform: @MainActor (ActionContext, String?) -> Void

    @MainActor func title(in context: ActionContext) -> String {
        label?(context) ?? title
    }

    /// A session action is only ever available with a session to act on.
    @MainActor func canRun(_ context: ActionContext, argument: String?) -> Bool {
        if section == .session, context.session == nil { return false }
        return isAvailable(context, argument)
    }
}

/// Every registered action, in the order keys try them and the palette lists them.
@MainActor
enum ActionRegistry {
    static let all: [PaletteAction] = sessionActions + launcherActions + pileActions + navigationActions + commandActions + triageActions + noteActions + panelActions + gridActions + draftActions + keyboardActions + onboardingActions

    private static let byID: [ActionID: PaletteAction] = Dictionary(all.map { ($0.id, $0) }) { first, _ in
        assertionFailure("Two actions are registered as \(first.id)")
        return first
    }

    static func action(_ id: ActionID) -> PaletteAction? {
        byID[id]
    }
}

extension ActionID {
    // Session
    static let askAnswer: ActionID = "ask.answer"
    static let askOpen: ActionID = "ask.open"
    static let gitCommit: ActionID = "git.commit"
    static let gitPush: ActionID = "git.push"
    static let gitPullRequest: ActionID = "git.pr"
    static let gitMerge: ActionID = "git.merge"
    static let sessionFork: ActionID = "session.fork"
    static let sessionRewind: ActionID = "session.rewind"
    static let sessionRename: ActionID = "session.rename"
    static let sessionRenameWorktree: ActionID = "session.rename-worktree"
    static let sessionOpenInEditor: ActionID = "session.editor"
    static let sessionTerminal: ActionID = "session.terminal"
    static let sessionDetail: ActionID = "session.detail"
    static let sessionPrevious: ActionID = "session.previous"
    static let sessionModel: ActionID = "session.model"
    static let sessionEffort: ActionID = "session.effort"
    static let sessionPermissionMode: ActionID = "session.permissions"
    static let sessionFastMode: ActionID = "session.fast"
    static let sessionInterrupt: ActionID = "session.interrupt"
    static let sessionStop: ActionID = "session.stop"
    static let sessionResume: ActionID = "session.resume"
    static let sessionRetry: ActionID = "session.retry"
    static let sessionArchive: ActionID = "session.archive"
    static let sessionCopyBranch: ActionID = "session.copy-branch"
    static let sessionCopyPath: ActionID = "session.copy-path"

    // Navigation
    static let focusMove: ActionID = "focus.move"
    static let focusNextBlocked: ActionID = "focus.next-blocked"
    static let tileOpen: ActionID = "tile.open"
    static let back: ActionID = "back"

    // Commands
    static let sessionNew: ActionID = "session.new"
    static let terminalNew: ActionID = "terminal.new"
    static let browserNew: ActionID = "browser.new"
    static let taskRun: ActionID = "task.run"
    static let taskRestart: ActionID = "task.restart"
    static let taskStop: ActionID = "task.stop"
    static let terminalClose: ActionID = "terminal.close"
    static let tileClose: ActionID = "tile.close"
    static let projectAdd: ActionID = "project.add"
    static let projectNew: ActionID = "project.new"
    static let projectShowInFinder: ActionID = "project.finder"
    static let projectRemove: ActionID = "project.remove"
    static let projectFilter: ActionID = "project.filter"
    static let projectByNumber: ActionID = "project.byNumber"
    static let showFilter: ActionID = "filter.show"
    static let cleanup: ActionID = "cleanup.open"
    static let settings: ActionID = "app.settings"
    static let palette: ActionID = "palette.open"
}
