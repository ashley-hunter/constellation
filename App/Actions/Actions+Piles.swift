import ConstellationCore
import Foundation
import SwiftUI

/// Fanning piles, the Needs you lens, and settling and unsettling.
extension ActionRegistry {
    /// Ahead of the desktop's own keys, so ↵ fans a focused pile before it would open the card.
    static var pileActions: [PaletteAction] {
        [
            PaletteAction(
                id: .pileFan, title: "Fan out pile", keywords: ["spread", "pile", "stack", "cards"], section: .navigation,
                keys: [KeyBinding("return"), KeyBinding("space")],
                isAvailable: { context, _ in
                    let model = context.model
                    guard context.surface == .desktop, !model.isPileFanned, let item = context.item else { return false }
                    return (model.geometry.stack(containing: item)?.count ?? 1) > 1
                },
                perform: { context, _ in
                    guard let item = context.item, let pile = context.model.pileID(of: item) else { return }
                    context.model.fanPile(pile)
                }
            ),
            PaletteAction(
                id: .lensToggle, title: "Needs you lens", keywords: ["dim", "focus", "attention", "blocked", "failed", "working", "filter"],
                systemImage: "scope", section: .command,
                // ⌘⇧N is New project, so this takes ⌘⌥N.
                keys: [KeyBinding("cmd+alt+n")],
                perform: { context, _ in context.model.toggleLens() }
            ),
            PaletteAction(
                id: .sidebarToggle, title: "Toggle Sidebar", keywords: ["projects", "filters", "menu", "show", "hide", "panel"],
                systemImage: "sidebar.left", section: .command,
                keys: [KeyBinding("ctrl+cmd+s")],
                perform: { context, _ in
                    let model = context.model
                    // In like a panel opening, out a little quicker, the piles re-flowing with it.
                    withAnimation(model.isSidebarShown ? .dismiss : .present) { model.isSidebarShown.toggle() }
                }
            ),
            PaletteAction(
                id: .sessionSettle, title: "Settle", keywords: ["done", "put away", "tidy", "finished", "pile", "hide"],
                systemImage: "tray.and.arrow.down", section: .session,
                keys: [KeyBinding("cmd+shift+e")],
                isAvailable: { context, _ in context.session.map(LifecycleRules.canSettle) ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.settle(id)
                }
            ),
            PaletteAction(
                id: .sessionUnsettle, title: "Unsettle", keywords: ["merged", "idle", "settled", "bring back", "restore", "pile"],
                systemImage: "arrow.uturn.up", section: .session,
                isAvailable: { context, _ in context.session.map(LifecycleRules.isSettled) ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.unsettle(id)
                }
            ),
        ]
    }
}

extension ActionID {
    static let pileFan: ActionID = "pile.fan"
    static let lensToggle: ActionID = "lens.toggle"
    static let sidebarToggle: ActionID = "sidebar.toggle"
    static let sessionSettle: ActionID = "session.settle"
    static let sessionUnsettle: ActionID = "session.unsettle"
}
