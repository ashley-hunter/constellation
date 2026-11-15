import ConstellationCore
import SwiftUI

/// One card on the desktop. Switches on what the item is, so answering, terminal and browser views
/// can each slot in here.
struct TileView: View {
    @Environment(AppModel.self) private var model
    let item: TileItem
    /// Off for a card behind another in a pile, whose float shadow would read as one more card below.
    var floats = true
    /// Off for a terminal card that only needs its face, not its live shell.
    var isLive = true

    var body: some View {
        Group {
            switch item {
            case .session(let id):
                if let session = model.sessionsByID[id] {
                    SessionTile(session: session, project: model.project(session.projectID))
                }
            case .terminal(let id):
                if let terminal = model.terminalsByID[id] {
                    switch terminal.kind {
                    case .browser: BrowserTile(browser: terminal, project: model.project(terminal.projectID))
                    case .note: NoteTile(note: terminal, project: model.project(terminal.projectID))
                    case .shell, .task: TerminalTile(terminal: terminal, project: model.project(terminal.projectID), isLive: isLive)
                    }
                }
            }
        }
        // Tiles float over the wallpaper, as on the canvas.
        .shadow(color: .black.opacity(floats ? 0.32 : 0), radius: 22, y: 8)
    }
}

struct SessionTile: View {
    let session: Session
    let project: Project?

    var body: some View {
        content
            .contextMenu {
                if session.isDraft { DraftTileMenu(session: session) } else { SessionTileMenu(session: session) }
            }
    }

    @ViewBuilder private var content: some View {
        if session.isDraft {
            DraftTile(session: session, project: project)
        } else {
            FullSessionTile(session: session, project: project)
        }
    }
}
