import AppKit
import ConstellationCore

/// What pulls you back from outside the app: the menu bar extra, the Dock badge and notifications.
extension AppModel {
    /// Blocked first, then failed, oldest activity first within each.
    var sessionsNeedingYou: (blocked: [Session], failed: [Session]) {
        let live = sessions.filter { $0.lifecycle != .archived }
        let byActivity: (Session, Session) -> Bool = { $0.lastActivityAt < $1.lastActivityAt }
        return (
            live.filter { $0.runState == .blocked }.sorted(by: byActivity),
            live.filter { if case .failed = $0.runState { true } else { false } }.sorted(by: byActivity)
        )
    }

    /// Brings the desktop forward and focuses the tile, clearing filters that would hide it.
    func reveal(_ item: TileItem) {
        if case .session(let id) = item, let session = sessionsByID[id] {
            if let projectFilter, projectFilter != session.projectID { self.projectFilter = nil }
            if !showFilter.matches(session) { showFilter = .all }
        }
        clearFront()
        openedSessionID = nil
        focusedItem = item
        Self.bringDesktopForward()
    }

    static func bringDesktopForward() {
        NSApp.activate()
        NSApp.windows.first { $0 is DesktopWindow }?.makeKeyAndOrderFront(nil)
    }
}
