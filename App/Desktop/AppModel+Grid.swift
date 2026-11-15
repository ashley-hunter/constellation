import AppKit
import ConstellationCore
import SwiftUI

/// The split screen's next slot while it shows the sessions to fill it with.
enum GridPicking: Hashable {
    /// No grid yet: the lone session open moves to the left half to make room for the slot. Only
    /// while `grid` is nil.
    case beside(UUID)
    /// The grid's next empty slot. Only while there is a grid, or one is being made from a pick.
    case nextSlot

    /// The lone session making room, when there's no grid yet.
    var base: UUID? {
        if case .beside(let id) = self { id } else { nil }
    }
}

/// The split screen: two to four sessions side by side over the desktop, each its own session view.
/// The focused tile is the opened session, so its keys, ⌥ answers and typing all go to it alone.
extension AppModel {
    /// Add to grid…: the next slot shows the sessions to pick from, Snap Assist style. With no grid
    /// yet, `base` (the session open, or the card whose menu it came from) takes the left half.
    func beginGridPicking(beside base: UUID?) {
        guard gridPicking == nil else { return }
        clearFront()
        if let grid {
            guard !grid.isFull else {
                notice = "The grid holds \(SessionGrid.capacity) sessions"
                return
            }
            withAnimation(.present) {
                self.grid?.isZoomed = false
                sessionDetail = nil
                gridPicking = .nextSlot
            }
        } else {
            guard let base, canJoinGrid(base) else { return }
            sessionDetail = nil
            gridReturnID = nil
            gridPicking = .beside(base)
            if openedSessionID != base { openSession(base) }
        }
        // The picker's field takes the keys from the reply box.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// The session picked for the slot joins the grid, and the next slot shows the picker while
    /// there's room and something left to pick.
    func pickForGrid(_ id: UUID) {
        guard let picking = gridPicking else { return }
        withAnimation(.present) {
            // Picking still, so the new tile's reply box doesn't take the keys from the picker.
            gridPicking = .nextSlot
            addToGrid(id, beside: picking.base)
            let goesOn = grid.map { !$0.isFull && !gridCandidates(beside: nil).isEmpty } ?? false
            if !goesOn { gridPicking = nil }
        }
        if gridPicking == nil, let grid { handKeys(to: grid.focusedID) }
    }

    /// esc on the picker: the slot goes and the grid keeps what was picked. A lone session goes
    /// back to its own view.
    func endGridPicking() {
        guard let picking = gridPicking else { return }
        if let base = picking.base, grid == nil { gridReturnID = base }
        withAnimation(.present) { gridPicking = nil }
        if let grid { handKeys(to: grid.focusedID) }
    }

    /// In the split screen, or the lone session making room for it.
    func gridHolds(_ id: UUID) -> Bool {
        grid?.contains(id) == true || gridPicking?.base == id
    }

    /// Splits the screen: `other` beside `base`, or added to the grid already showing. Focus goes
    /// to the one added.
    func addToGrid(_ other: UUID, beside base: UUID?) {
        guard canJoinGrid(other) else { return }
        if var grid {
            guard grid.add(other) else {
                notice = "The grid holds \(SessionGrid.capacity) sessions"
                return
            }
            withAnimation(.present) { self.grid = grid }
        } else {
            guard let base, canJoinGrid(base), let grid = SessionGrid([base, other], focus: other) else { return }
            // Picking goes on into the grid being made.
            clearFront(keeping: .gridPicking)
            sessionDetail = nil
            self.grid = grid
        }
        openSession(other)
    }

    /// Takes a tile out. With one session left, it opens on its own instead.
    func removeFromGrid(_ id: UUID) {
        guard var grid, grid.contains(id) else { return }
        if let last = grid.remove(id) {
            self.grid = nil
            // Still picking, the one left makes room for the picker on its own.
            if gridPicking != nil { gridPicking = .beside(last) }
            openSession(last)
            return
        }
        withAnimation(.present) { self.grid = grid }
        if openedSessionID != grid.focusedID { openSession(grid.focusedID) }
    }

    /// Back to the desktop, the focused tile's card focused.
    func closeGrid() {
        guard let grid else { return }
        dismantleGrid()
        sessionDetail = nil
        focusedItem = .session(grid.focusedID)
        openedSessionID = nil
    }

    func focusGridTile(_ id: UUID) {
        guard grid?.contains(id) == true, openedSessionID != id else { return }
        // A tile clicked while picking leaves the picker its slot and the keys.
        clearFront(keeping: .gridPicking)
        openSession(id)
    }

    func moveGridFocus(_ step: SessionGrid.Step) {
        guard let next = grid?.neighbour(step) else { return }
        focusGridTile(next)
    }

    /// The focused tile fills the grid's space, or goes back to its place. Its pane goes with the zoom.
    func toggleGridZoom() {
        // Not while picking, as the zoomed tile would cover the slot.
        guard grid != nil, gridPicking == nil else { return }
        withAnimation(.present) {
            grid?.isZoomed.toggle()
            if grid?.isZoomed == false { sessionDetail = nil }
        }
    }

    /// Sessions archived or gone since they were put in the grid leave it.
    func pruneGrid() {
        if let base = gridPicking?.base, !canJoinGrid(base) { gridPicking = nil }
        guard let grid else { return }
        for id in grid.ids where !canJoinGrid(id) { removeFromGrid(id) }
    }

    /// A launched session still on the desktop.
    func canJoinGrid(_ id: UUID) -> Bool {
        guard let session = sessionsByID[id] else { return false }
        return !session.isDraft && session.lifecycle != .archived && !pendingArchives.contains(id)
    }

    /// The sessions that could join the grid beside `base`, in the picker's order (see
    /// `GridPick.candidates`), those matching `query` when there is one.
    func gridCandidates(beside base: UUID?, matching query: String = "") -> [Session] {
        let taken = Set(grid?.ids ?? []).union([base, gridPicking?.base].compactMap { $0 }).union(pendingArchives)
        return GridPick.candidates(sessionsByID.values, excluding: taken, query: query) { self.project($0.projectID)?.name }
    }

    /// The opened session changed (see `openedSessionID`): one in the grid takes focus there, and
    /// anything else, or nothing, leaves the grid.
    func gridFollowsOpened() {
        if let id = gridReturnID, openedSessionID != id { gridReturnID = nil }
        if let base = gridPicking?.base, openedSessionID != base { gridPicking = nil }
        guard let grid else { return }
        guard let id = openedSessionID, grid.contains(id) else { return dismantleGrid() }
        if grid.focusedID != id { self.grid?.focus(id) }
        // While picking, the picker's field keeps the keys.
        if gridPicking == nil { handKeys(to: id) }
    }

    /// The split screen goes, and its picker with it. The one way the grid leaves the screen.
    private func dismantleGrid() {
        grid = nil
        gridPicking = nil
    }

    /// The keys leave the tile that had them, so typing never lands in the wrong session, and go to
    /// the new tile's reply box unless a permission waits there, whose ⌥ keys a field would type.
    func handKeys(to id: UUID) {
        if let active = activeComposerID, active != id {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        guard activeComposerID != id, sessionsByID[id]?.nextAsk?.isPermission != true else { return }
        composerFocusRequest = id
    }

    /// What the opened-tile slot shows over the split screen: only a terminal opened over it.
    var soloOpenedTile: TileItem? {
        guard grid != nil || gridPicking != nil else { return openedTile }
        if case .terminal? = openedTile { return openedTile }
        return nil
    }
}

extension ActionID {
    static let gridAdd: ActionID = "grid.add"
    static let gridRemove: ActionID = "grid.remove"
    static let gridClose: ActionID = "grid.close"
    static let gridZoom: ActionID = "grid.zoom"
    static let gridMove: ActionID = "grid.move"
}

extension ActionRegistry {
    static var gridActions: [PaletteAction] {
        [
            PaletteAction(
                id: .gridAdd, title: "Add to grid…", keywords: ["split", "screen", "side by side", "tile", "pane", "grid", "snap"],
                systemImage: "rectangle.split.2x1", section: .session,
                keys: [KeyBinding("ctrl+cmd+n")],
                isAvailable: { context, _ in
                    let model = context.model
                    guard model.gridPicking == nil, model.grid?.isFull != true else { return false }
                    if model.grid != nil { return !model.gridCandidates(beside: nil).isEmpty }
                    guard let id = context.sessionID, model.canJoinGrid(id) else { return false }
                    return !model.gridCandidates(beside: id).isEmpty
                },
                perform: { context, _ in context.model.beginGridPicking(beside: context.sessionID) }
            ),
            PaletteAction(
                id: .gridRemove, title: "Remove from grid", keywords: ["split", "unsplit", "tile", "pane"],
                systemImage: "rectangle", section: .session,
                isAvailable: { context, _ in context.sessionID.map { context.model.grid?.contains($0) == true } ?? false },
                perform: { context, _ in
                    guard let id = context.sessionID else { return }
                    context.model.removeFromGrid(id)
                }
            ),
            PaletteAction(
                id: .gridZoom, title: "Zoom tile", keywords: ["grid", "split", "fill", "focus", "unzoom"],
                systemImage: "arrow.up.left.and.arrow.down.right",
                label: { context in context.model.grid?.isZoomed == true ? "Back to grid" : "Zoom tile" },
                section: .command,
                keys: [KeyBinding("ctrl+cmd+return")],
                isAvailable: { context, _ in context.model.grid != nil },
                unavailableReason: "Open a grid first",
                perform: { context, _ in context.model.toggleGridZoom() }
            ),
            PaletteAction(
                id: .gridClose, title: "Close grid", keywords: ["split", "unsplit", "tiles", "desktop"],
                systemImage: "xmark.rectangle", section: .command,
                isAvailable: { context, _ in context.model.grid != nil },
                unavailableReason: "No grid is open",
                perform: { context, _ in context.model.closeGrid() }
            ),
            PaletteAction(
                id: .gridMove, title: "Move between tiles", section: .navigation,
                // Typed as String, or it would bind "ctrl+cmd+Optional("left")".
                keys: ["left", "right", "up", "down"].map { (name: String) in KeyBinding("ctrl+cmd+\(name)", argument: name) },
                isAvailable: { context, argument in
                    guard let grid = context.model.grid, !grid.isZoomed, let step = argument.flatMap(SessionGrid.Step.init(name:)) else { return false }
                    return grid.neighbour(step) != nil
                },
                perform: { context, argument in
                    guard let step = argument.flatMap(SessionGrid.Step.init(name:)) else { return }
                    context.model.moveGridFocus(step)
                }
            ),
        ]
    }
}

extension SessionGrid.Step {
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
