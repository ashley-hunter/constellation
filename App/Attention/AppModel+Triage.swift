import ConstellationCore
import Foundation

/// Where triage is: the sessions it has opened, in order, and the one showing.
struct TriageRun {
    var visited: [UUID] = []
    var index = 0
    /// The run state the showing session opened with. Once that changes (answered, retried,
    /// replied to, stopped) it no longer needs you and triage moves on.
    var openedState: RunState?

    var current: UUID? { visited.indices.contains(index) ? visited[index] : nil }
}

/// Triage: the session view opens on the oldest thing that needs you, moves on by itself once it
/// stops needing you, and closes back to the desktop when nothing is left. Over the split screen,
/// one in the grid is focused in its tile; anything else leaves the grid for the session view.
extension AppModel {
    /// Everything triage would open, in its order (see `Triage.queue`).
    var triageQueue: [UUID] {
        Triage.queue(sessionsByID.values.filter { !pendingArchives.contains($0.id) })
    }

    /// Where the strip says triage is, as in "2 of 5".
    var triageProgress: (position: Int, total: Int)? {
        guard let triage else { return nil }
        let visited = Set(triage.visited)
        return (triage.index + 1, triage.visited.count + triageQueue.filter { !visited.contains($0) }.count)
    }

    /// Opens the oldest thing that needs you, or while triaging moves on to the next.
    func startTriage() {
        if triage != nil { return stepTriage(by: 1) }
        guard let first = triageQueue.first else {
            notice = "All caught up"
            return
        }
        showInTriage(first, run: TriageRun())
    }

    /// ⌘] skips on to the next session that needs you, ⌘[ goes back to the one before.
    func stepTriage(by step: Int) {
        guard let run = triage else { return }
        if step < 0 {
            guard let index = run.visited.indices.prefix(run.index).last(where: { isTriageable(run.visited[$0]) }) else { return }
            return showInTriage(run.visited[index], run: run, at: index)
        }
        let queue = triageQueue
        // Back a step or two, the ones after it come again while they still need you.
        if let index = run.visited.indices.dropFirst(run.index + 1).first(where: { queue.contains(run.visited[$0]) }) {
            return showInTriage(run.visited[index], run: run, at: index)
        }
        guard let next = queue.first(where: { !run.visited.contains($0) }) else { return finishTriage() }
        showInTriage(next, run: run, at: run.visited.count)
    }

    /// Back to the desktop, saying so, and how many skipped ones still wait.
    func finishTriage() {
        let skipped = triage.map { run in run.visited.filter(triageQueue.contains).count } ?? 0
        triage = nil
        clearFront()
        // The split screen stays, as it was there before triage.
        if openedSessionID != nil, grid == nil { closeSession() }
        notice = skipped == 0 ? "All caught up" : "All caught up, apart from \(skipped) you skipped"
    }

    /// A session changed while triaging: once the one showing stops needing you, the next opens.
    func triageSessionsChanged() {
        guard let id = triage?.current, isTriageDone(id) else { return }
        // Not inside the change itself, which may still be partway through.
        Task { @MainActor [weak self] in
            guard let self, self.triage?.current == id, self.isTriageDone(id) else { return }
            self.stepTriage(by: 1)
        }
    }

    private func isTriageDone(_ id: UUID) -> Bool {
        guard let session = sessionsByID[id], session.lifecycle != .archived else { return true }
        return session.runState != triage?.openedState
    }

    private func isTriageable(_ id: UUID) -> Bool {
        sessionsByID[id].map { $0.lifecycle != .archived } ?? false
    }

    /// Opens `id` as triage's session at `index` of what it has visited, closing whatever covers
    /// the session view first (see `clearFront`).
    private func showInTriage(_ id: UUID, run: TriageRun, at index: Int = 0) {
        clearFront()
        if openedSessionID != id { leaveOpenDraft() }
        var run = run
        if index == run.visited.count { run.visited.append(id) }
        run.index = index
        run.openedState = sessionsByID[id]?.runState
        triage = run
        openSession(id)
    }
}
