import ConstellationCore
import SwiftUI

/// How a session view sits in the split screen.
struct GridTileRole: Equatable {
    /// Holds the keys: its reply box may take them, and it wears the focus ring.
    var isFocused: Bool
    /// Fills the grid's space alone, with its full header and pane.
    var isZoomed: Bool
}

/// Where the split screen's tiles sit in `bounds`, and while picking the empty slot the next one
/// will land in. Before there's a grid, the lone session making room is its one tile.
struct GridLayout {
    struct Tile {
        let id: UUID
        let frame: CGRect
    }

    let tiles: [Tile]
    let slot: CGRect?

    init(grid: SessionGrid?, picking: GridPicking?, in bounds: CGRect) {
        let ids = grid?.ids ?? picking?.base.map { [$0] } ?? []
        if picking != nil, let frames = GridPick.frames(count: ids.count, in: bounds, gap: SessionGridView.gap) {
            tiles = zip(ids, frames.tiles).map(Tile.init)
            slot = frames.slot
        } else {
            tiles = zip(ids, SessionGrid.frames(count: ids.count, in: bounds, gap: SessionGridView.gap)).map(Tile.init)
            slot = nil
        }
    }
}

/// The split screen: two to four session views tiled over the desktop (see `SessionGrid`). Zoomed,
/// the focused tile grows over the grid's whole space and the others fade. While picking, the next
/// slot is an inset well holding the sessions to fill it with.
struct SessionGridView: View {
    @Environment(AppModel.self) private var model
    let size: CGSize
    /// The grid and picker as last shown, so the tiles stay while the overlay closes.
    @State private var shown = Shown()

    static let gap: CGFloat = 10

    private struct Shown: Equatable {
        var grid: SessionGrid?
        var picking: GridPicking?
    }

    var body: some View {
        let isOpen = model.grid != nil || model.gridPicking != nil
        let grid = isOpen ? model.grid : shown.grid
        let picking = isOpen ? model.gridPicking : shown.picking
        let bounds = model.maximisedFrame(in: size)
        let layout = GridLayout(grid: grid, picking: picking, in: bounds)
        ZStack(alignment: .topLeading) {
            // A click in a gap between tiles doesn't reach the scrim, which would close the grid.
            Color.clear
                .contentShape(.rect)
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
            ForEach(layout.tiles, id: \.id) { tile in
                if let session = model.sessionsByID[tile.id] {
                    // While picking, the picker has the keys and wears the ring.
                    let isFocused = tile.id == grid?.focusedID && picking == nil
                    let isZoomed = grid?.isZoomed == true && isFocused
                    let place = isZoomed ? bounds : tile.frame
                    GridTile(session: session, role: GridTileRole(isFocused: isFocused, isZoomed: isZoomed))
                        .frame(width: place.width, height: place.height)
                        .position(x: place.midX, y: place.midY)
                        .opacity(grid?.isZoomed == true && !isFocused ? 0 : 1)
                        .allowsHitTesting(grid?.isZoomed != true || isFocused)
                        .zIndex(isZoomed ? 1 : 0)
                }
            }
            if let slot = layout.slot {
                GridSlotPicker(columns: slot.width >= 560 ? 2 : 1, filled: layout.tiles.count)
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: Shown(grid: model.grid, picking: model.gridPicking), initial: true) { _, now in
            if now.grid != nil || now.picking != nil { shown = now }
            model.pruneGrid()
        }
        .onChange(of: model.sessionsByID.count) { model.pruneGrid() }
        .onChange(of: model.pendingArchives) { model.pruneGrid() }
        // A click into another tile's reply box moves focus there with it.
        .onChange(of: model.activeComposerID) { _, id in
            if let id { model.focusGridTile(id) }
        }
    }
}

private struct GridTile: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let role: GridTileRole

    var body: some View {
        SessionView(session: session, gridTile: role)
            .overlay {
                // A tile waiting on you is lit as its card is, so you can see which one needs you.
                if session.runState == .blocked, !role.isFocused {
                    TravellingEdge(color: Palette.ask)
                }
            }
            .overlay(FocusRing(cornerRadius: PanelSurface.cornerRadius, isOn: role.isFocused && !role.isZoomed))
            .simultaneousGesture(TapGesture().onEnded { model.focusGridTile(session.id) })
    }
}

/// A grid tile's compact header: what it is, and its zoom and close.
struct GridTileHeader: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            RunGlyph(runState: session.runState)
            if let project = model.project(session.projectID) { ProjectMark(project: project) }
            Text(session.title)
                .font(.ui(12.5, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if session.runState == .blocked {
                Circle().fill(Palette.ask).frame(width: 6, height: 6)
                    .accessibilityLabel("Needs you")
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if model.grid?.isFull == false, model.gridPicking == nil {
                    Button { model.perform(.gridAdd, on: .session(session.id)) } label: {
                        Image(systemName: "plus.rectangle").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(IconButtonStyle(width: 24, height: 22))
                    .help("Add to grid" + key(.gridAdd))
                    .accessibilityLabel("Add to grid")
                }
                Button { zoom() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(width: 24, height: 22))
                .help("Zoom" + key(.gridZoom))
                Button { model.removeFromGrid(session.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(width: 24, height: 22))
                .help("Remove from grid")
                .accessibilityLabel("Remove from grid")
            }
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
    }

    private func zoom() {
        model.focusGridTile(session.id)
        model.toggleGridZoom()
    }

    private func key(_ id: ActionID) -> String {
        model.binding(for: id).map { " (\($0.label))" } ?? ""
    }
}
