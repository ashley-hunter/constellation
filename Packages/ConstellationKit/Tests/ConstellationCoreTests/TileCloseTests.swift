import Foundation
import Testing
@testable import ConstellationCore

@Suite struct TileCloseTests {
    @Test func aTerminalCloses() {
        let id = UUID()
        #expect(TileClose.route(.terminal(id), session: nil, draftIsEmpty: true) == .closeTerminal(id))
    }

    @Test(arguments: [RunState.preparing(.worktree), .working, .blocked])
    func busyOrBlockedSessionsAskBeforeArchiving(_ runState: RunState) {
        let session = makeSession(runState: runState)
        #expect(TileClose.route(.session(session.id), session: session, draftIsEmpty: true) == .archive(session.id, asks: true))
    }

    @Test(arguments: [RunState.done, .failed(.turnError), .interrupted])
    func finishedSessionsArchiveStraightAway(_ runState: RunState) {
        let session = makeSession(runState: runState)
        #expect(TileClose.route(.session(session.id), session: session, draftIsEmpty: true) == .archive(session.id, asks: false))
    }

    @Test func aDraftAsksOnlyWhenSomethingIsWritten() {
        let draft = makeSession(runState: .draft)
        #expect(TileClose.route(.session(draft.id), session: draft, draftIsEmpty: true) == .discardDraft(draft.id, asks: false))
        #expect(TileClose.route(.session(draft.id), session: draft, draftIsEmpty: false) == .discardDraft(draft.id, asks: true))
    }

    @Test func goneOrArchivedSessionsHaveNothingToClose() {
        let archived = makeSession(runState: .done, lifecycle: .archived)
        #expect(TileClose.route(.session(archived.id), session: archived, draftIsEmpty: true) == nil)
        #expect(TileClose.route(.session(UUID()), session: nil, draftIsEmpty: true) == nil)
    }
}
