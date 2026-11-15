import ConstellationCore
import Foundation

/// Running registered actions, from menus, keys and the palette.
extension AppModel {
    /// The tile actions act on when none is given: the opened tile in front (a terminal opened
    /// over the session view, as `surface` puts it), then focus. A sheet or zoomed image over it
    /// doesn't change it, so the palette acts on what it was opened over.
    var actionTarget: TileItem? {
        openedTile ?? focusedItem
    }

    func actionContext(on item: TileItem? = nil, via trigger: ActionTrigger) -> ActionContext {
        ActionContext(model: self, item: item ?? actionTarget, trigger: trigger)
    }

    func canPerform(_ id: ActionID, on item: TileItem? = nil, argument: String? = nil, via trigger: ActionTrigger = .menu) -> Bool {
        guard let action = ActionRegistry.action(id) else { return false }
        return action.canRun(actionContext(on: item, via: trigger), argument: argument)
    }

    /// Runs the action when it is available. Returns whether it ran.
    @discardableResult
    func perform(_ id: ActionID, on item: TileItem? = nil, argument: String? = nil, via trigger: ActionTrigger = .menu) -> Bool {
        guard let action = ActionRegistry.action(id) else { return false }
        let context = actionContext(on: item, via: trigger)
        guard action.canRun(context, argument: argument) else { return false }
        action.perform(context, argument)
        return true
    }

    /// The first binding of an action in the keymap, for its chip in the palette. A binding with
    /// an argument only labels that argument's row.
    func binding(for id: ActionID, argument: String? = nil) -> KeyBinding? {
        keyboard.keymap.entries(for: id.rawValue, argument: argument).first?.rule.binding
    }

    /// The first ⌘ chord bound to an action, for its menu item.
    func menuShortcut(for id: ActionID, argument: String? = nil) -> KeyStroke? {
        keyboard.keymap.entries(for: id.rawValue, argument: argument)
            .first { $0.rule.strokes.count == 1 && $0.rule.strokes[0].modifiers.contains(.command) }?.rule.strokes[0]
    }

    // MARK: Recents

    /// Palette rows run recently, newest first, keyed by `paletteKey`.
    var paletteRecents: [String] {
        if let known = recentPaletteKeys { return known }
        let stored = (try? services.store.paletteRecents()) ?? []
        recentPaletteKeys = stored
        return stored
    }

    func recordPaletteUse(_ key: String) {
        recentPaletteKeys = PaletteRanking.recording(key, in: paletteRecents)
        let store = services.store
        Task.detached { try? store.recordPaletteUse(key) }
    }

    static func paletteKey(_ id: ActionID, argument: String?) -> String {
        argument.map { "\(id.rawValue):\($0)" } ?? id.rawValue
    }
}
