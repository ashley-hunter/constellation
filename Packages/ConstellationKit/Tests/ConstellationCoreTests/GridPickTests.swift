import Foundation
import Testing
@testable import ConstellationCore

@Suite struct GridPickTests {
    private func session(_ title: String = "Session", _ state: RunState = .working, at date: Date, lifecycle: Lifecycle = .seen) -> Session {
        var session = makeSession(title: title, runState: state, lifecycle: lifecycle)
        session.lastActivityAt = date
        return session
    }

    @Test func needingYouComesFirstThenTheLatest() {
        let old = session(at: t0 + 1)
        let recent = session(at: t0 + 9)
        let done = session("Done", .done, at: t0 + 2, lifecycle: .unseen)
        let failed = session("Failed", .failed(.turnError), at: t0 + 5, lifecycle: .unseen)
        var blocked = makeSession(runState: .blocked)
        blocked.asks = [permissionAsk("a", session: blocked, at: t0 + 3)]
        let order = GridPick.candidates([old, done, recent, failed, blocked], excluding: []).map(\.id)
        #expect(order == [blocked.id, failed.id, done.id, recent.id, old.id])
    }

    @Test func leavesOutTheGridArchivedAndDrafts() {
        let inGrid = session(at: t0)
        let kept = session(at: t0)
        var archived = session(at: t0)
        archived.lifecycle = .archived
        let draft = makeSession(runState: .draft)
        let order = GridPick.candidates([inGrid, kept, archived, draft], excluding: [inGrid.id]).map(\.id)
        #expect(order == [kept.id])
    }

    @Test func aQueryMatchesEveryWordInTheTitleOrProject() {
        let login = session("Fix login redirect", at: t0)
        let docs = session("Write docs", at: t0 + 1)
        let names = [login.id: "web", docs.id: "api"]
        let matched = GridPick.candidates([login, docs], excluding: [], query: "LOGIN web") { names[$0.id] }
        #expect(matched.map(\.id) == [login.id])
        #expect(GridPick.candidates([login, docs], excluding: [], query: "api") { names[$0.id] }.map(\.id) == [docs.id])
    }

    @Test func theSlotIsTheNextPlaceInTheLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 1010, height: 610)
        let one = GridPick.frames(count: 1, in: bounds, gap: 10)
        #expect(one?.tiles == [CGRect(x: 0, y: 0, width: 500, height: 610)])
        #expect(one?.slot == CGRect(x: 510, y: 0, width: 500, height: 610))
        let three = GridPick.frames(count: 3, in: bounds, gap: 10)
        #expect(three?.slot == CGRect(x: 510, y: 310, width: 500, height: 300))
        #expect(GridPick.frames(count: 4, in: bounds, gap: 10) == nil)
    }
}
