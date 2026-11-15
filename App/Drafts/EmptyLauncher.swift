import ConstellationCore
import Foundation
import Observation

/// The "Start a session" card on an empty desktop: what you have typed to filter it, the selected
/// row, and the draft it is opening.
@Observable
@MainActor
final class EmptyLauncher {
    /// A draft opened from a row, which the launcher hides behind while it's open.
    struct Launch: Equatable {
        let draftID: UUID
    }

    var query = "" {
        didSet {
            // The search field writes its text back on ↵; only a real change starts the rows over.
            guard query != oldValue else { return }
            selection = 0
            PointerHover.settle()
        }
    }

    var selection = 0
    var launch: Launch?
    var presence = Presence.auto

    enum Presence {
        /// Shows while the desktop is empty.
        case auto
        /// ⌘N brought it up over the desktop, whatever is on it, until a project is picked or esc.
        case summoned
        /// esc put it away, for settled cards behind it. ponytail: until relaunch or ⌘N.
        case dismissed
    }
}

extension AppModel {
    /// No live sessions or terminals, and at least one project. Settled sessions don't count,
    /// and nor does the draft the launcher is opening.
    var showsLauncher: Bool {
        guard onboarding == nil, !projects.isEmpty else { return false }
        if launcher.presence == .summoned { return true }
        guard terminalsByID.isEmpty, !(launcher.presence == .dismissed && canDismissLauncher) else { return false }
        return !sessionsByID.values.contains { session in
            session.id != launcher.launch?.draftID
                && [.full, .titleBar].contains(LifecycleRules.presentation(of: session))
        }
    }

    /// Something is behind the launcher to go back to: a settled or put-away session.
    var canDismissLauncher: Bool {
        launcher.presence == .summoned || sessionsByID.values.contains { !$0.isDraft }
    }

    /// Keys reach the launcher only while it is in front (see `surface`).
    var launcherTakesKeys: Bool {
        surface == .launcher
    }

    /// The card fades while its draft's panel is out, and comes back as an empty one leaves.
    var launcherIsCovered: Bool {
        launcher.launch.map { $0.draftID != discardingDraftID } ?? false
    }

    /// Projects most recently used first, narrowed by what you typed.
    var launcherProjects: [Project] {
        let ordered = projects.enumerated().sorted { a, b in
            let (lhs, rhs) = (lastUsed(a.element.id), lastUsed(b.element.id))
            if lhs != rhs { return (lhs ?? .distantPast) > (rhs ?? .distantPast) }
            return a.offset < b.offset
        }.map(\.element)
        let query = launcher.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ordered }
        return FuzzyMatch.rank(query, ordered, limit: ordered.count) { "\($0.name) \($0.rootPath.lastPathComponent)" }
    }

    /// When a session last did anything in the project, archived ones included only while loaded.
    func lastUsed(_ projectID: UUID) -> Date? {
        sessionsByID.values.filter { $0.projectID == projectID && !$0.isDraft }.map(\.lastActivityAt).max()
    }

    /// ⌘N: the launcher over whatever is open, the project you'd most likely want already selected.
    func summonLauncher(selecting projectID: UUID?) {
        clearFront()
        // Closing the session takes the grid and triage with it.
        if openedSessionID != nil { closeSession() }
        launcher.query = ""
        launcher.presence = .summoned
        launcher.selection = launcherProjects.firstIndex { $0.id == projectID } ?? 0
    }

    /// esc or a click outside: the card goes, summoned or not, until ⌘N.
    func dismissLauncher() {
        launcher.query = ""
        launcher.presence = .dismissed
    }

    /// Opens a draft in the row's project.
    func openFromLauncher(_ projectID: UUID) {
        newDraft(in: projectID, fromLauncher: true)
        launcher.query = ""
    }

    /// ↵: the selected project row, or "New project…" and "Open folder…" after them.
    func openSelectedLauncherRow() {
        let rows = launcherProjects
        if rows.indices.contains(launcher.selection) {
            openFromLauncher(rows[launcher.selection].id)
        } else if let row = LauncherActionRow(rawValue: launcher.selection - rows.count) {
            runLauncherRow(row)
        }
    }

    /// The selection runs through the project rows, then the two action rows, and wraps.
    func moveLauncherSelection(by offset: Int) {
        let count = launcherProjects.count + LauncherActionRow.allCases.count
        PointerHover.settle()
        launcher.selection = (launcher.selection + offset + count) % count
    }

    func runLauncherRow(_ row: LauncherActionRow) {
        launcher.query = ""
        presentProjectFlow(row == .newProject ? .newProject : .openFolder)
    }
}

/// The rows under the projects in the launcher, in order.
enum LauncherActionRow: Int, CaseIterable {
    case newProject, openFolder
}
