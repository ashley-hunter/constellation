import AppKit
import ConstellationCore

/// Jumping between tiles and the global hotkeys.
extension ActionRegistry {
    static var keyboardActions: [PaletteAction] {
        let digits = JumpHints.digits
        return [
            PaletteAction(
                id: .tileFocus, title: "Open tile", section: .navigation,
                keys: digits.map { KeyBinding("cmd+\($0)", argument: $0) },
                isAvailable: { context, argument in context.model.acceptsDigit(argument) },
                perform: { context, argument in context.model.typeJumpDigit(argument, opening: true) }
            ),
            PaletteAction(
                id: .tileSplit, title: "Focus tile", section: .navigation,
                keys: digits.map { KeyBinding("cmd+shift+\($0)", argument: $0) },
                isAvailable: { context, argument in context.model.acceptsDigit(argument) },
                perform: { context, argument in context.model.typeJumpDigit(argument, opening: false) }
            ),
            PaletteAction(
                id: .hintsShow, title: "Jump to a tile", section: .navigation,
                // Plain letters type into a focused session's composer, so this takes ⌘J.
                keys: [KeyBinding("cmd+j")],
                isAvailable: { context, _ in context.surface == .desktop && !context.model.hintTargets.isEmpty },
                perform: { context, _ in context.model.showJumpHints() }
            ),
            PaletteAction(
                id: .noticeUndo, title: "Undo", keywords: ["undo", "archive", "restore"],
                systemImage: "arrow.uturn.backward", section: .command,
                keys: [KeyBinding("cmd+z")],
                // ⌘Z in a text field undoes typing.
                isAvailable: { context, _ in context.model.canUndoNotice && !context.model.keyboard.isEditingText },
                perform: { context, _ in context.model.undoNotice() }
            ),
            PaletteAction(
                id: .stackNext, title: "Next in stack", keywords: ["cycle", "terminal", "behind", "card"],
                section: .navigation,
                // Tab turns the focused pile; ⌘] stays as an alias.
                keys: [KeyBinding("tab"), KeyBinding("cmd+]")],
                isAvailable: { context, _ in context.surface == .desktop && context.model.focusedStack != nil && !context.model.keyboard.isEditingText },
                perform: { context, _ in context.model.cycleStack(by: 1) }
            ),
            PaletteAction(
                id: .stackPrevious, title: "Previous in stack", keywords: ["cycle", "terminal", "behind", "card"],
                section: .navigation,
                keys: [KeyBinding("shift+tab"), KeyBinding("cmd+[")],
                isAvailable: { context, _ in context.surface == .desktop && context.model.focusedStack != nil && !context.model.keyboard.isEditingText },
                perform: { context, _ in context.model.cycleStack(by: -1) }
            ),
            PaletteAction(
                id: .focusPreviousBlocked, title: "Previous that needs you", keywords: ["needs you", "waiting", "ask", "jump", "back", "failed", "attention"],
                systemImage: "exclamationmark.circle", section: .command,
                keys: [KeyBinding("alt+shift+tab")],
                isAvailable: { context, _ in context.surface == .desktop && !context.model.attentionItems.isEmpty },
                perform: { context, _ in context.model.focusAttention(by: -1) }
            ),
            PaletteAction(
                id: .appSummon, title: "Summon Constellation", section: .navigation,
                perform: { context, _ in
                    let model = context.model
                    NSApp.activate()
                    // A session waiting on you takes focus over the card that had it, so ↵ opens it.
                    if !model.isDesktopCovered, let id = model.oldestBlocked,
                       model.focusedItem.flatMap(model.session(for:))?.runState != .blocked {
                        model.jump(to: .session(id), opening: false)
                    } else if model.focusedItem == nil {
                        model.focus(model.geometry.targets.first)
                    }
                }
            ),
            PaletteAction(
                id: .appSummonBlocked, title: "Jump to the oldest blocked session", section: .navigation,
                isAvailable: { context, _ in context.model.oldestBlocked != nil },
                perform: { context, _ in
                    let model = context.model
                    guard let id = model.oldestBlocked else { return }
                    NSApp.activate()
                    model.clearFront()
                    if model.openedSessionID != nil { model.closeSession() }
                    model.openSession(id)
                }
            ),
        ]
    }

    /// Hotkeys that work from any app, registered with Carbon. Tile digits take ⌃⌥ because ⌥+digit
    /// types characters on many layouts (# on British, [ ] { } on German), and a hotkey would steal them.
    static var globalHotKeyDefaults: [KeyRule] {
        [KeyRule(KeyBinding("alt+space").strokes, ActionID.appSummon.rawValue), KeyRule(KeyBinding("alt+shift+space").strokes, ActionID.appSummonBlocked.rawValue)]
            + JumpHints.digits.map { KeyRule(KeyBinding("ctrl+alt+\($0)").strokes, ActionID.tileFocus.rawValue, argument: $0) }
    }

    /// Every action's default keys, in registry order, for the keymap and the keys.conf template.
    static let keymapDefaults = KeymapDefaults(
        bindings: all.flatMap { action in action.keys.map { KeyRule($0, action.id.rawValue) } },
        globals: globalHotKeyDefaults
    )

    static let knownActionIDs = Set(all.map(\.id.rawValue))
}

extension ActionID {
    static let tileFocus: ActionID = "tile.focus"
    static let tileSplit: ActionID = "tile.split"
    static let hintsShow: ActionID = "hints.show"
    static let focusPreviousBlocked: ActionID = "focus.previous-blocked"
    static let noticeUndo: ActionID = "notice.undo"
    static let stackNext: ActionID = "stack.next"
    static let stackPrevious: ActionID = "stack.previous"
    static let appSummon: ActionID = "app.summon"
    static let appSummonBlocked: ActionID = "app.summon-blocked"
}
