import ConstellationCore
import SwiftUI

/// The tile's right-click menu: rename, open the worktree, git, copy its branch or path, archive.
struct SessionTileMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let item = TileItem.session(session.id)
        ActionButton(.sessionRename, on: item)
        if session.usesWorktree {
            ActionButton(.sessionRenameWorktree, on: item)
        }
        Divider()
        ActionButton(.sessionOpenInEditor, on: item)
        Menu("Open in") {
            OpenInEditorItems(sessionID: session.id)
        }
        ActionButton(.sessionTerminal, on: item)
        ActionButton(.gridAdd, on: item)
        Divider()
        GitActionsMenu(session: session)
        Divider()
        ActionButton(.sessionCopyBranch, on: item)
        ActionButton(.sessionCopyPath, on: item)
        Divider()
        ActionButton(.sessionInterrupt, on: item)
        ActionButton(.sessionStop, on: item)
        if LifecycleRules.isSettled(session) {
            ActionButton(.sessionUnsettle, on: item)
        } else if LifecycleRules.canSettle(session) {
            ActionButton(.sessionSettle, on: item)
        }
        ActionButton(.sessionArchive, on: item)
        if let summary = model.usage[session.id]?.tooltip {
            Divider()
            Text(summary)
        }
    }
}
