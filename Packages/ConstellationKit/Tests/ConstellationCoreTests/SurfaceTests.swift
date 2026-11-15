import Foundation
import Testing
@testable import ConstellationCore

@Suite struct SurfaceTests {
    private typealias S = Surface<String>
    private let session = UUID(), terminal = UUID(), tile = UUID()

    @Test func eachLayerBeatsEverythingUnderIt() {
        #expect(S(onboarding: true, attachment: true, sheet: "git", terminal: terminal, session: session) == .onboarding)
        #expect(S(attachment: true, sheet: "git", terminal: terminal, session: session) == .attachment)
        #expect(S(sheet: "git", terminal: terminal, session: session) == .sheet("git"))
        #expect(S(terminal: terminal, grid: (false, false), session: session, launcher: true) == .terminal(terminal))
        #expect(S(grid: (true, false), session: session, launcher: true) == .grid(focused: session, isPicking: true, isZoomed: false))
        #expect(S(session: session, launcher: true, inlineComposer: tile) == .session(session))
        #expect(S(launcher: true, inlineComposer: tile) == .launcher)
        #expect(S(inlineComposer: tile) == .inlineComposer(tile))
        #expect(S() == .desktop)
    }

    @Test func aTerminalOverASessionIsWhatsInFront() {
        let surface = S(terminal: terminal, session: session)
        #expect(surface == .terminal(terminal))
        #expect(surface.sessionID == nil)
        #expect(surface.coversDesktop)
    }

    @Test func theGridsSessionIsTheOpenedOne() {
        #expect(S(grid: (false, true), session: session).sessionID == session)
        #expect(S(session: session).sessionID == session)
    }

    @Test func onlyPanelsAndSheetsCoverTheDesktop() {
        #expect(!S(onboarding: true).coversDesktop)
        #expect(!S(launcher: true).coversDesktop)
        #expect(!S(inlineComposer: tile).coversDesktop)
        #expect(!S().coversDesktop)
        #expect(S(attachment: true).coversDesktop)
        #expect(S(sheet: "palette").coversDesktop)
    }
}

@Suite struct NoticeSlotTests {
    @Test func aNewNoticeHandsBackWhatTheOldOneHeld() {
        var slot = NoticeSlot<Int>()
        #expect(slot.show("Archived A.", holding: 1) == nil)
        #expect(slot.show("Archived B.", holding: 2) == 1)
        #expect(slot.notice?.text == "Archived B.")
        #expect(slot.notice?.held == 2)
    }

    @Test func aPlainNoticeStillReleasesTheUndoItReplaces() {
        var slot = NoticeSlot<Int>()
        slot.show("Archived A.", holding: 1)
        #expect(slot.show("Couldn't send") == 1)
        #expect(slot.undo() == nil)
    }

    @Test func undoTakesBackWhatIsHeldAndClears() {
        var slot = NoticeSlot<Int>()
        slot.show("Archived A.", holding: 1)
        #expect(slot.undo() == 1)
        #expect(slot.notice == nil)
        #expect(slot.show("Next") == nil)
    }

    @Test func expiringOnlyTouchesTheNoticeStillShowing() {
        var slot = NoticeSlot<Int>()
        slot.show("Archived A.", holding: 1)
        let first = slot.notice!.id
        slot.show("Archived B.", holding: 2)
        #expect(slot.expire(first) == nil)
        #expect(slot.notice?.text == "Archived B.")
        #expect(slot.expire(slot.notice!.id) == 2)
        #expect(slot.notice == nil)
    }

    @Test func dismissingReleasesWhatIsHeld() {
        var slot = NoticeSlot<Int>()
        slot.show("Archived A.", holding: 1)
        #expect(slot.show(nil) == 1)
    }
}
