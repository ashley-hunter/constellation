import CoreGraphics
import Foundation
import Testing
@testable import ConstellationCore

@Suite struct PilesTests {
    /// The 1728 by 1117 screen beside the sidebar.
    private let screen = CGRect(x: 296, y: 40, width: 1400, height: 1040)

    private func piles(_ sessions: [Session], terminals: [Terminal] = []) -> [Pile] {
        Piles.list(sessions: sessions, terminals: terminals)
    }

    private func terminal(in folder: String, session: Session? = nil, project: UUID = projectA, createdAt: Date = t0, running: Bool = false) -> Terminal {
        Terminal(projectID: project, workingDirectory: URL(filePath: folder), sessionID: session?.id, title: "zsh", state: running ? .running : .idle, createdAt: createdAt)
    }

    // MARK: Membership

    @Test func aDoneSessionWhosePRFailsOrNeedsChangesNeedsYou() {
        var session = makeSession(runState: .done, lifecycle: .seen, pullRequest: 7)
        #expect(PileRank(session) == .seen)
        session.pullRequest?.checks = CheckSummary(state: .failure, passed: 4, total: 5)
        #expect(PileRank(session) == .needsYou)
        session.pullRequest?.checks = CheckSummary(state: .success, passed: 5, total: 5)
        session.pullRequest?.reviewDecision = .changesRequested
        #expect(PileRank(session) == .needsYou)
        session.lifecycle = .settled
        #expect(PileRank(session) == .needsYou)
        // While the agent works on it, it's working, not waiting on you.
        session.runState = .working
        #expect(PileRank(session) == .working)
    }

    @Test func sessionsSharingAWorktreeAndItsTerminalsFormOnePile() {
        let a = makeSession(worktree: "/wt/login", createdAt: t0, runState: .done, lifecycle: .seen)
        let b = makeSession(worktree: "/wt/login/", createdAt: t0 + 1, runState: .done, lifecycle: .seen)
        let owned = terminal(in: "/somewhere/else", session: a, createdAt: t0 + 2)
        let inside = terminal(in: "/wt/login/src", createdAt: t0 + 3)
        let result = piles([a, b], terminals: [owned, inside])
        #expect(result.count == 1)
        #expect(Set(result[0].cards) == [.session(a.id), .session(b.id), .terminal(owned.id), .terminal(inside.id)])
    }

    @Test func everyProjectsPilesShareOneDesktop() {
        let a = makeSession(worktree: "/wt/a", createdAt: t0)
        let b = makeSession(worktree: "/wt/b", createdAt: t0 + 1)
        let other = makeSession(project: projectB, worktree: "/wt/c", createdAt: t0 + 2)
        let result = piles([a, b, other])
        #expect(result.map(\.cards) == [[.session(a.id)], [.session(b.id)], [.session(other.id)]])
        #expect(result.map(\.projectID) == [projectA, projectA, projectB])
    }

    @Test func aPileKeepsItsProjectAndBranchFromTheWorkThatStartedIt() {
        let first = makeSession(worktree: "/wt/a", createdAt: t0 + 1, runState: .done, lifecycle: .seen)
        let later = makeSession(worktree: "/wt/a", createdAt: t0 + 2, runState: .blocked)
        let shell = terminal(in: "/wt/a", project: projectB, createdAt: t0)
        let pile = piles([later, first], terminals: [shell])[0]
        #expect(pile.top == .session(later.id))
        #expect(pile.projectID == projectA)
        #expect(pile.branch == first.branch)
        let alone = piles([], terminals: [shell])[0]
        #expect(alone.projectID == projectB && alone.branch.isEmpty)
    }

    @Test func everyProjectsSettledWorkGathersInOneTrayLast() {
        let live = makeSession(worktree: "/wt/live", runState: .done, lifecycle: .seen)
        let merged = makeSession(worktree: "/wt/m", createdAt: t0, runState: .done, lifecycle: .merged)
        let idle = makeSession(project: projectB, worktree: "/wt/i", createdAt: t0 + 1, runState: .done, lifecycle: .idle)
        let archived = makeSession(worktree: "/wt/x", runState: .done, lifecycle: .archived)
        let result = piles([merged, idle, live, archived])
        #expect(result.map(\.isSettled) == [false, true])
        #expect(result[1].cards == [.session(merged.id), .session(idle.id)])
        #expect(result[1].projectID == nil)
    }

    /// Live work gets worktree piles; whatever has settled, by hand, by moving on, merging or going
    /// idle, shares the one Settled tray.
    @Test func onlyLiveWorkHasWorktreePiles() {
        let live: [Session] = [
            makeSession(worktree: "/wt/ask", runState: .blocked),
            makeSession(worktree: "/wt/fail", runState: .failed(.turnError)),
            makeSession(worktree: "/wt/work", runState: .working),
            makeSession(worktree: "/wt/prep", runState: .preparing(.setup)),
            makeSession(worktree: "/wt/stop", runState: .interrupted, lifecycle: .seen),
            makeSession(worktree: "/wt/new", runState: .done, lifecycle: .unseen),
            makeSession(worktree: "/wt/kept", runState: .done, lifecycle: .kept),
            // In a project of its own, as a draft otherwise joins its project's live work.
            makeSession(project: projectB, worktree: "/wt/draft", runState: .draft),
        ]
        let settled = [Lifecycle.settled, .merged, .idle].map { makeSession(worktree: "/wt/\($0)", runState: .done, lifecycle: $0) }
        let result = piles(live + settled)
        #expect(result.count == live.count + 1)
        #expect(result.dropLast().allSatisfy { !$0.isSettled && $0.cards.count == 1 })
        #expect(Set(result.last!.cards) == Set(settled.map { .session($0.id) }))
    }

    /// A terminal stays on its worktree's pile while a live session is there, and keeps a pile of
    /// its own on that folder once they've all settled.
    /// A note joins the pile on its folder like a shell, as calm as an idle one.
    @Test func aNoteJoinsItsFoldersPile() {
        let session = makeSession(worktree: "/wt/login", runState: .working)
        let note = Terminal(projectID: projectA, workingDirectory: URL(filePath: "/wt/login"), title: "Plan", createdAt: t0 + 1, note: "# Plan")
        let result = piles([session], terminals: [note])
        #expect(result.map(\.cards) == [[.session(session.id), .terminal(note.id)]])
        #expect(result[0].rank(of: .terminal(note.id)) == .seen)
    }

    @Test func aTerminalStaysWithLiveWorkOnItsWorktree() {
        let done = makeSession(worktree: "/wt/a", createdAt: t0, runState: .done, lifecycle: .settled)
        let working = makeSession(worktree: "/wt/a", createdAt: t0 + 1, runState: .working)
        let shell = terminal(in: "/wt/a", session: done)
        let together = piles([done, working], terminals: [shell])
        #expect(together.map(\.cards) == [[.session(working.id), .terminal(shell.id)], [.session(done.id)]])
        var finished = working
        finished.runState = .done
        finished.lifecycle = .settled
        let apart = piles([done, finished], terminals: [shell])
        #expect(apart.map(\.cards) == [[.terminal(shell.id)], [.session(finished.id), .session(done.id)]])
    }

    @Test func aSettledSessionsTerminalStaysOnItsFolder() {
        let merged = makeSession(worktree: "/wt/m", runState: .done, lifecycle: .merged)
        let shell = terminal(in: "/wt/m", session: merged)
        #expect(piles([merged], terminals: [shell]).map(\.cards) == [[.terminal(shell.id)], [.session(merged.id)]])
    }

    @Test func terminalsOnTheSameFolderPileTogether() {
        let one = terminal(in: "/p/ledger", createdAt: t0)
        let two = terminal(in: "/p/ledger", createdAt: t0 + 1)
        #expect(piles([], terminals: [two, one]).map(\.cards) == [[.terminal(one.id), .terminal(two.id)]])
    }

    @Test func aPilesKeyComesBackAsTheSamePile() {
        for id in [Pile.ID.worktree("/wt/a"), .settled] { #expect(Pile.ID(key: id.key) == id) }
    }

    // MARK: Drafts

    @Test func aDraftJoinsItsProjectsMainCheckoutPile() {
        var main = makeSession(worktree: "/p/ledger", createdAt: t0)
        main.usesWorktree = false
        main.lastActivityAt = t0
        var recent = makeSession(worktree: "/wt/login", createdAt: t0 + 1)
        recent.lastActivityAt = t0 + 10
        let draft = makeSession(worktree: "/wt/3f9a2c1e", createdAt: t0 + 2, runState: .draft)
        let result = piles([main, recent, draft])
        #expect(result.count == 2)
        #expect(result.first { $0.id == .worktree("/p/ledger") }?.cards.contains(.session(draft.id)) == true)
    }

    @Test func withoutAMainCheckoutADraftJoinsTheMostRecentSessionsPile() {
        var older = makeSession(worktree: "/wt/a", createdAt: t0)
        older.lastActivityAt = t0 + 1
        var recent = makeSession(worktree: "/wt/b", createdAt: t0 + 1)
        recent.lastActivityAt = t0 + 5
        let other = makeSession(project: projectB, worktree: "/wt/c", createdAt: t0 + 2)
        let draft = makeSession(worktree: "/wt/3f9a2c1e", createdAt: t0 + 3, runState: .draft)
        let result = piles([older, recent, other, draft])
        #expect(result.map(\.id) == [.worktree("/wt/a"), .worktree("/wt/b"), .worktree("/wt/c")])
        #expect(result[1].cards.contains(.session(draft.id)))
    }

    @Test func aDraftWithNoLiveWorkInItsProjectGetsAPileWithNoBranch() {
        let elsewhere = makeSession(project: projectB, worktree: "/wt/c", createdAt: t0)
        let settled = makeSession(worktree: "/wt/old", createdAt: t0, runState: .done, lifecycle: .settled)
        let draft = makeSession(worktree: "/wt/3f9a2c1e", createdAt: t0 + 1, runState: .draft)
        let result = piles([elsewhere, settled, draft])
        let own = result.first { $0.cards == [.session(draft.id)] }
        #expect(own?.id == .worktree("/wt/3f9a2c1e"))
        #expect(own?.projectID == projectA)
        // So its label falls back to the project's name rather than the generated folder.
        #expect(own?.branch == "")
    }

    @Test func aDraftDoesntTakeOverThePileItJoins() {
        let work = makeSession(worktree: "/wt/a", createdAt: t0 + 5)
        let draft = makeSession(worktree: "/wt/3f9a2c1e", createdAt: t0, runState: .draft)
        let pile = piles([work, draft])[0]
        #expect(pile.branch == work.branch)
        #expect(Set(pile.cards) == [.session(work.id), .session(draft.id)])
    }

    // MARK: Order in a pile

    @Test func theMostUrgentCardIsOnTop() {
        let states: [(RunState, Lifecycle)] = [(.done, .seen), (.done, .unseen), (.working, .seen), (.failed(.turnError), .seen), (.blocked, .seen)]
        let sessions = states.enumerated().map { index, state in
            makeSession(worktree: "/wt/shared", createdAt: t0 + Double(index), runState: state.0, lifecycle: state.1)
        }
        let pile = piles(sessions)[0]
        #expect(pile.cards == sessions.reversed().map { .session($0.id) })
        #expect(pile.cards.map(pile.rank(of:)) == [.needsYou, .failed, .working, .unseenDone, .seen])
    }

    @Test func aChatComesBeforeItsTerminalsAtTheSameRank() {
        let chat = makeSession(worktree: "/wt/a", createdAt: t0 + 5, runState: .done, lifecycle: .seen)
        let shell = terminal(in: "/wt/a", session: chat, createdAt: t0)
        #expect(piles([chat], terminals: [shell])[0].cards == [.session(chat.id), .terminal(shell.id)])

        let running = terminal(in: "/wt/a", session: chat, createdAt: t0, running: true)
        #expect(piles([chat], terminals: [running])[0].cards == [.terminal(running.id), .session(chat.id)])
    }

    @Test func aHeldPileKeepsItsCardOrderUntilLetGo() {
        let first = makeSession(worktree: "/wt/a", createdAt: t0, runState: .done, lifecycle: .unseen)
        let shell = terminal(in: "/wt/a", session: first)
        let before = piles([first], terminals: [shell])
        var seen = first
        seen.lifecycle = .seen
        let running = terminal(in: "/wt/a", session: first, createdAt: t0 + 5, running: true)
        let now = piles([seen], terminals: [shell, running])
        #expect(now[0].cards == [.terminal(running.id), .session(first.id), .terminal(shell.id)])
        let held = Piles.holding(now, to: [before[0].id: before[0].cards])
        #expect(held[0].cards == [.session(first.id), .terminal(shell.id), .terminal(running.id)])
    }

    @Test func aCardThatNeedsYouRisesEvenInAHeldPile() {
        let chat = makeSession(worktree: "/wt/a", createdAt: t0, runState: .done, lifecycle: .seen)
        let other = makeSession(worktree: "/wt/a", createdAt: t0 + 1, runState: .done, lifecycle: .unseen)
        let before = piles([chat, other])
        #expect(before[0].cards.first == .session(other.id))
        var asking = chat
        asking.runState = .blocked
        let held = Piles.holding(piles([asking, other]), to: [before[0].id: before[0].cards])
        #expect(held[0].cards.first == .session(chat.id))
    }

    /// A pile you've reordered keeps your order whatever its cards do; a new card goes on top when
    /// it needs you or has failed, otherwise at the end.
    @Test func aReorderedPileKeepsYourOrder() {
        let a = makeSession(worktree: "/wt/a", createdAt: t0, runState: .done, lifecycle: .seen)
        let b = makeSession(worktree: "/wt/a", createdAt: t0 + 1, runState: .done, lifecycle: .seen)
        let order: [Pile.ID: [TileItem]] = [.worktree("/wt/a"): [.session(b.id), .session(a.id)]]
        var asking = a
        asking.runState = .blocked
        let quiet = makeSession(worktree: "/wt/a", createdAt: t0 + 2, runState: .done, lifecycle: .seen)
        let failing = makeSession(worktree: "/wt/a", createdAt: t0 + 3, runState: .failed(.turnError))
        let result = Piles.ordered(piles([asking, b, quiet, failing]), by: order)
        #expect(result[0].cards == [.session(failing.id), .session(b.id), .session(a.id), .session(quiet.id)])
    }

    // MARK: Unsettling

    @Test func unsettlingBringsASessionBackUntilItSettlesAgain() {
        let now = t0 + 10 * 86_400
        let merged = makeSession(worktree: "/wt/m", runState: .done, lifecycle: .merged)
        let back = LifecycleRules.apply(.unsettled, to: merged, at: now)
        #expect(back.lifecycle == .kept)
        #expect(PileRank(back) == .seen)
        #expect(LifecycleRules.apply(.tick, to: back, at: now + 3_600).lifecycle == .kept)
        #expect(LifecycleRules.apply(.tick, to: back, at: now + LifecycleRules.idleAfter).lifecycle == .idle)
        #expect(LifecycleRules.apply(.pullRequestMerged, to: back, at: now).lifecycle == .merged)
        let live = makeSession(worktree: "/wt/l", runState: .done, lifecycle: .unseen)
        #expect(LifecycleRules.apply(.unsettled, to: live, at: now) == live)
    }

    // MARK: Slots

    /// `count` piles of one card each, alternating between two projects, with a settled tray last.
    private func desktop(_ count: Int, settled: Bool = true) -> [Pile] {
        var sessions = (0..<count).map { index in
            makeSession(project: index.isMultiple(of: 2) ? projectA : projectB, worktree: "/wt/\(index)", createdAt: t0 + Double(index), runState: .done, lifecycle: .seen)
        }
        if settled { sessions.append(makeSession(worktree: "/wt/merged", runState: .done, lifecycle: .merged)) }
        return piles(sessions)
    }

    /// A desktop of random piles, the same every run.
    private func randomDesktop(seed: UInt64, count: Int) -> [Pile] {
        var random = PileRandom(seed: seed)
        let projects = (0..<4).map { _ in random.uuid() }
        let states: [(RunState, Lifecycle)] = [(.blocked, .seen), (.failed(.turnError), .seen), (.working, .unseen), (.done, .unseen), (.done, .seen), (.done, .merged)]
        var sessions: [Session] = []
        var terminals: [Terminal] = []
        for index in 0..<count {
            let state = states[Int.random(in: 0..<states.count, using: &random)]
            let project = projects[Int.random(in: 0..<projects.count, using: &random)]
            var session = makeSession(project: project, worktree: "/wt/\(Int.random(in: 0...count, using: &random))", createdAt: t0 + Double(index), runState: state.0, lifecycle: state.1)
            session.id = random.uuid()
            sessions.append(session)
            if Bool.random(using: &random) {
                terminals.append(Terminal(id: random.uuid(), projectID: project, workingDirectory: session.worktreePath, sessionID: session.id, title: "zsh", createdAt: t0))
            }
        }
        return piles(sessions, terminals: terminals)
    }

    @Test func aSavedSlotIsKept() {
        let desktop = desktop(2)
        let layout = PilesLayout.place(desktop, slots: [desktop[0].id: PileSlot(column: 2, row: 1)], in: screen)
        #expect(layout.slots[desktop[0].id] == PileSlot(column: 2, row: 1))
        #expect(layout.slots[desktop[1].id] == PileSlot(column: 0, row: 0))
    }

    @Test func theSettledTrayStartsBottomRight() {
        let layout = PilesLayout.place(desktop(3), in: screen)
        #expect(layout.slots[.settled] == layout.grid!.corner)
        let tray = layout.cards.first { $0.pile == .settled }!.frame
        #expect(layout.cards.allSatisfy { $0.frame.maxX <= tray.maxX && $0.frame.maxY <= tray.maxY })
    }

    /// A project's first pile starts top left; the next goes in the free slot nearest it.
    @Test func aNewPileLandsBesideItsProject() {
        let ledger = makeSession(worktree: "/wt/ledger", createdAt: t0)
        let docs = makeSession(project: projectB, worktree: "/wt/docs", createdAt: t0 + 1)
        let before = PilesLayout.place(piles([ledger, docs]), slots: [.worktree("/wt/ledger"): PileSlot(column: 3, row: 2)], in: screen)
        #expect(before.slots[.worktree("/wt/docs")] == PileSlot(column: 0, row: 0))
        let newcomer = makeSession(worktree: "/wt/new", createdAt: t0 + 2)
        let after = PilesLayout.place(piles([ledger, docs, newcomer]), slots: before.slots, in: screen)
        let slot = after.slots[.worktree("/wt/new")]!
        let nearest = after.grid!.slots.filter { $0 != PileSlot(column: 3, row: 2) }.map { after.grid!.distance($0, PileSlot(column: 3, row: 2)) }.min()!
        #expect(after.grid!.distance(slot, PileSlot(column: 3, row: 2)) == nearest)
        #expect(after.slots[.worktree("/wt/ledger")] == PileSlot(column: 3, row: 2))
        #expect(after.slots[.worktree("/wt/docs")] == PileSlot(column: 0, row: 0))
    }

    /// While a filter hides a pile, a new one doesn't take its slot, so it has it back afterwards.
    @Test func aNewPileLeavesAHiddenPilesSlotAlone() {
        let shown = desktop(1, settled: false)
        let layout = PilesLayout.place(shown, reserved: [PileSlot(column: 0, row: 0)], in: screen)
        #expect(layout.slots[shown[0].id] == PileSlot(column: 1, row: 0))
    }

    @Test func twoPilesSavedInOneSlotPartWays() {
        let desktop = desktop(3)
        let shared = PileSlot(column: 1, row: 1)
        let layout = PilesLayout.place(desktop, slots: Dictionary(uniqueKeysWithValues: desktop.map { ($0.id, shared) }), in: screen)
        #expect(layout.slots[desktop[0].id] == shared)
        #expect(Set(layout.slots.values).count == desktop.count)
    }

    /// The desktop shrinks only when there are more piles than slots, and then only as far as it
    /// must; a saved slot the smaller grid doesn't have is given a new one.
    @Test func aCrowdedDesktopShrinksJustEnough() {
        #expect(PilesLayout.place(desktop(6), in: screen).scale == 1)
        let crowd = desktop(40)
        let saved = [crowd[0].id: PileSlot(column: 30, row: 30)]
        let layout = PilesLayout.place(crowd, slots: saved, in: screen)
        #expect(layout.scale < 1)
        #expect(layout.grid!.count >= crowd.count)
        #expect(PileGrid(in: screen, scale: layout.scale + 0.02).count < crowd.count)
        #expect(layout.grid!.contains(layout.slots[crowd[0].id]!))
        #expect(Set(layout.slots.values).count == crowd.count)
    }

    @Test func pilesNeverOverlapAndStayOnScreen() {
        for bounds in [screen, CGRect(x: 296, y: 40, width: 900, height: 700), CGRect(x: 0, y: 0, width: 2400, height: 1300)] {
            for count in [1, 3, 8, 20, 45] {
                let layout = PilesLayout.place(randomDesktop(seed: UInt64(count) * 31, count: count), in: bounds)
                let boxes = Dictionary(grouping: layout.cards, by: \.pile).mapValues(Self.bounds(of:))
                for (pile, box) in boxes {
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(box), "\(pile) leaves \(bounds)")
                    let label = layout.labels.first { $0.pile == pile }!.frame
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(label))
                    for (other, otherBox) in boxes where other != pile {
                        #expect(!box.insetBy(dx: 0.5, dy: 0.5).intersects(otherBox), "\(pile) overlaps \(other)")
                        #expect(!label.insetBy(dx: 0.5, dy: 0.5).intersects(otherBox), "\(pile)'s label is under \(other)")
                    }
                }
            }
        }
    }

    /// Piles keep their places however their work changes: nothing climbs for being urgent.
    @Test func aPileStaysPutWhenItsWorkChanges() {
        let quiet = (0..<4).map { makeSession(worktree: "/wt/\($0)", createdAt: t0 + Double($0), runState: .done, lifecycle: .seen) }
        let before = PilesLayout.place(piles(quiet), in: screen)
        var busy = quiet
        busy[3].runState = .blocked
        busy[1].runState = .failed(.turnError)
        busy[0].lifecycle = .merged
        let after = PilesLayout.place(piles(busy), slots: before.slots, in: screen)
        for index in 1..<4 {
            #expect(after.slots[.worktree("/wt/\(index)")] == before.slots[.worktree("/wt/\(index)")])
            #expect(after.frames[.session(busy[index].id)] == before.frames[.session(quiet[index].id)])
        }
    }

    @Test func placementIsTheSameEveryTime() {
        let desktop = randomDesktop(seed: 7, count: 12)
        #expect(PilesLayout.place(desktop, in: screen) == PilesLayout.place(desktop, in: screen))
    }

    @Test func droppingAPileOnAnotherSwapsThem() {
        let desktop = desktop(2, settled: false)
        let layout = PilesLayout.place(desktop, in: screen)
        let (a, b) = (desktop[0].id, desktop[1].id)
        let target = layout.dropSlot(of: a, by: CGVector(dx: layout.grid!.step.width + 20, dy: -10))
        #expect(target == layout.slots[b])
        let swapped = PilesLayout.moving(a, to: target!, in: layout.slots)
        #expect(swapped[a] == layout.slots[b] && swapped[b] == layout.slots[a])
        let free = PileSlot(column: 0, row: 2)
        let moved = PilesLayout.moving(a, to: free, in: layout.slots)
        #expect(moved[a] == free && moved[b] == layout.slots[b])
    }

    // MARK: Exposé

    @Test func exposeIsTheSameEveryTime() {
        let desktop = randomDesktop(seed: 7, count: 12)
        let order = desktop.reversed().map(\.id)
        #expect(PilesLayout.place(desktop, order: order, in: screen) == PilesLayout.place(desktop, order: order, in: screen))
    }

    @Test func exposePilesNeverOverlapAndStayOnScreen() {
        for bounds in [screen, CGRect(x: 296, y: 40, width: 900, height: 700), CGRect(x: 0, y: 0, width: 2400, height: 1300)] {
            for count in [1, 2, 3, 5, 8, 20, 45] {
                let layout = PilesLayout.place(randomDesktop(seed: UInt64(count) * 31, count: count), order: [], in: bounds)
                #expect(layout.scale >= PileMetrics.minScale && layout.scale <= PileMetrics.maxScale)
                for (pile, place) in layout.places {
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(place), "\(pile) leaves \(bounds)")
                    for (other, otherPlace) in layout.places where other != pile {
                        #expect(!place.insetBy(dx: 0.5, dy: 0.5).intersects(otherPlace), "\(pile) overlaps \(other)")
                    }
                }
                let boxes = Dictionary(grouping: layout.cards, by: \.pile).mapValues(Self.bounds(of:))
                for (pile, box) in boxes {
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(box), "\(pile)'s cards leave \(bounds)")
                    #expect(bounds.insetBy(dx: -1, dy: -1).contains(layout.labels.first { $0.pile == pile }!.frame))
                }
            }
        }
    }

    /// Fewer piles come out bigger, until the cap, and the rows stay within one of each other.
    @Test func fewerPilesAreBiggerUpToTheCap() {
        let scales = [1, 2, 3, 4, 6, 9, 14, 24, 40].map { PilesLayout.place(desktop($0, settled: false), order: [], in: screen).scale }
        #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(scales[0] == PileMetrics.maxScale)
        #expect(scales.last! < 1)
        let layout = PilesLayout.place(desktop(7, settled: false), order: [], in: screen)
        let rows = Dictionary(grouping: layout.places.values, by: \.minY).mapValues(\.count).values
        #expect(rows.max()! - rows.min()! <= 1)
    }

    /// Reading the piles left to right and top to bottom gives back the saved order.
    @Test func exposeReadsInTheSavedOrder() {
        let desktop = desktop(9)
        var random = PileRandom(seed: 3)
        let order = desktop.filter { !$0.isSettled }.map(\.id).shuffled(using: &random) + [.settled]
        let layout = PilesLayout.place(desktop, order: order, in: screen)
        #expect(layout.order == order)
        let reading = layout.places.sorted { a, b in (a.value.minY, a.value.minX) < (b.value.minY, b.value.minX) }.map(\.key)
        #expect(reading == order)
        #expect(layout.targets == order.map { id in desktop.first { $0.id == id }!.top })
    }

    @Test func aNewPileLandsAfterItsProjectsLastPile() {
        let a1 = makeSession(worktree: "/wt/a1", createdAt: t0)
        let b1 = makeSession(project: projectB, worktree: "/wt/b1", createdAt: t0 + 1)
        let a2 = makeSession(worktree: "/wt/a2", createdAt: t0 + 2)
        let b2 = makeSession(project: projectB, worktree: "/wt/b2", createdAt: t0 + 3)
        let saved: [Pile.ID] = [.worktree("/wt/b1"), .worktree("/wt/a1"), .worktree("/wt/b2")]
        let layout = PilesLayout.place(piles([a1, b1, a2, b2]), order: saved, in: screen)
        #expect(layout.order == [.worktree("/wt/b1"), .worktree("/wt/a1"), .worktree("/wt/a2"), .worktree("/wt/b2")])
        // A project's first pile goes at the end, before the tray.
        let other = makeSession(project: UUID(), worktree: "/wt/c", createdAt: t0 + 4)
        let merged = makeSession(worktree: "/wt/m", runState: .done, lifecycle: .merged)
        let more = PilesLayout.place(piles([a1, b1, a2, b2, other, merged]), order: [.settled] + layout.order, in: screen)
        #expect(more.order == layout.order + [.worktree("/wt/c"), .settled])
    }

    @Test func theSettledTrayComesLastInExpose() {
        let desktop = desktop(5)
        let layout = PilesLayout.place(desktop, order: [.settled] + desktop.dropLast().map(\.id), in: screen)
        #expect(layout.order.last == .settled)
        let tray = layout.places[.settled]!
        #expect(layout.places.values.allSatisfy { $0.minY < tray.minY || ($0.minY == tray.minY && $0.minX <= tray.minX) })
        #expect(PilesLayout.moving(.settled, to: desktop[0].id, in: layout.order) == layout.order)
        #expect(PilesLayout.moving(desktop[0].id, to: .settled, in: layout.order).last == .settled)
    }

    @Test func exposePilesStayPutWhenTheirWorkChanges() {
        let quiet = (0..<5).map { makeSession(project: $0 < 3 ? projectA : projectB, worktree: "/wt/\($0)", createdAt: t0 + Double($0), runState: .done, lifecycle: .seen) }
        let before = PilesLayout.place(piles(quiet), order: [], in: screen)
        var busy = quiet
        busy[4].runState = .blocked
        busy[2].runState = .failed(.turnError)
        busy[1].runState = .working
        let after = PilesLayout.place(piles(busy), order: before.order, in: screen)
        #expect(after.order == before.order)
        #expect(after.places == before.places)
        #expect(after.frames == before.frames)
    }

    /// A filtered-out pile keeps its place in the order; the rest close up and grow.
    @Test func filteringReflowsTheRestBigger() {
        // Enough that all of them come out under the cap.
        let desktop = desktop(24, settled: false)
        let all = PilesLayout.place(desktop, order: [], in: screen)
        let shown = desktop.filter { $0.projectID == projectA }
        let filtered = PilesLayout.place(shown, order: all.order, in: screen)
        #expect(filtered.order == all.order)
        #expect(Set(filtered.places.keys) == Set(shown.map(\.id)))
        #expect(filtered.scale > all.scale)
    }

    @Test func droppingAPileOnAnotherTakesItsPlaceInTheOrder() {
        let desktop = desktop(4, settled: false)
        let ids = desktop.map(\.id)
        let layout = PilesLayout.place(desktop, order: ids, in: screen)
        let (from, to) = (layout.places[ids[0]]!, layout.places[ids[2]]!)
        let target = layout.dropTarget(of: ids[0], by: CGVector(dx: to.midX - from.midX + 10, dy: to.midY - from.midY - 10))
        #expect(target == ids[2])
        #expect(PilesLayout.moving(ids[0], to: ids[2], in: ids) == [ids[1], ids[2], ids[0], ids[3]])
        #expect(PilesLayout.moving(ids[3], to: ids[1], in: ids) == [ids[0], ids[3], ids[1], ids[2]])
        #expect(layout.dropTarget(of: ids[1], by: CGVector(dx: 5, dy: 5)) == ids[1])
    }

    /// Between two projects' piles side by side the gap is a little wider than within one.
    @Test func aProjectsPilesSitALittleCloser() {
        let sessions = [projectA, projectA, projectB].enumerated().map { makeSession(project: $1, worktree: "/wt/\($0)", createdAt: t0 + Double($0)) }
        let layout = PilesLayout.place(piles(sessions), order: [], in: CGRect(x: 0, y: 0, width: 1400, height: 400))
        let places = (0..<3).map { layout.places[.worktree("/wt/\($0)")]! }
        #expect(places.map(\.minY) == [places[0].minY, places[0].minY, places[0].minY])
        #expect(places[2].minX - places[1].maxX > places[1].minX - places[0].maxX)
    }

    @Test func aDraggedPileFollowsThePointerAboveTheRest() {
        let desktop = desktop(2, settled: false)
        let rest = PilesLayout.place(desktop, in: screen)
        let dragged = PilesLayout.place(desktop, in: screen, state: PilesState(drag: PileDrag(.pile(desktop[0].id), offset: CGVector(dx: 30, dy: 40))))
        let item = desktop[0].top
        #expect(dragged.frames[item] == rest.frames[item]!.offsetBy(dx: 30, dy: 40))
        #expect(dragged.labels[0].frame == rest.labels[0].frame.offsetBy(dx: 30, dy: 40))
        #expect(dragged.cards.first { $0.item == item }!.z > dragged.cards.filter { $0.pile != desktop[0].id }.map(\.z).max()!)
    }

    // MARK: A pile on the screen

    /// The upright box a set of cards fills once turned.
    private static func bounds(of cards: [PilesLayout.Card]) -> CGRect {
        cards.map { PilesLayout.turnedBounds(of: $0.frame, by: $0.rotation) }.reduce(CGRect.null) { $0.union($1) }
    }

    @Test func aPileTakesOneFootprintHoweverDeep() {
        let chat = makeSession(worktree: "/wt/deep", runState: .done, lifecycle: .seen)
        let shells = (0..<8).map { terminal(in: "/wt/deep", session: chat, createdAt: t0 + Double($0)) }
        let layout = PilesLayout.place(piles([chat], terminals: shells), in: screen)
        let union = Self.bounds(of: layout.cards)
        #expect(union.width <= PileMetrics.footprint.width * layout.scale)
        #expect(union.height <= PileMetrics.footprint.height * layout.scale)
        #expect(layout.cards.filter { $0.role == .top }.count == 1)
        #expect(layout.cards.filter { $0.depth > 0 }.allSatisfy { abs($0.rotation) <= PileMetrics.maxRotation })
        #expect(layout.targets == [.session(chat.id)])
        #expect(layout.labels[0].frame.minY >= union.maxY - 0.5)
    }

    /// An untidy stack of photos: the top card square, the few behind it a few points out from under
    /// it either way and turned one way then the other, the rest hidden square beneath.
    @Test func aPileIsAnUntidyStackNotACascade() {
        let chat = makeSession(worktree: "/wt/deep", runState: .done, lifecycle: .seen)
        let shells = (0..<6).map { terminal(in: "/wt/deep", session: chat, createdAt: t0 + Double($0)) }
        let layout = PilesLayout.place(piles([chat], terminals: shells), in: screen)
        let cards = layout.cards.sorted { $0.depth < $1.depth }
        let top = cards[0].frame
        #expect(cards[0].rotation == 0)
        let behind = cards[1...PileMetrics.maxVisibleBehind]
        for card in behind {
            let dx = abs(card.frame.minX - top.minX), dy = abs(card.frame.minY - top.minY)
            #expect(dx >= PileMetrics.behindOffset.lowerBound * layout.scale - 0.5 && dx <= PileMetrics.behindOffset.upperBound * layout.scale + 0.5)
            #expect(dy >= PileMetrics.behindOffset.lowerBound * layout.scale - 0.5 && dy <= PileMetrics.behindOffset.upperBound * layout.scale + 0.5)
            #expect(abs(card.rotation) >= PileMetrics.behindRotation.lowerBound)
        }
        for (a, b) in zip(behind, behind.dropFirst()) { #expect(a.rotation.sign != b.rotation.sign) }
        #expect(cards.dropFirst(PileMetrics.maxVisibleBehind + 1).allSatisfy { $0.frame == top && $0.rotation == 0 })
    }

    @Test func theFocusedCardTurnsItsPileToTheTop() {
        let chat = makeSession(worktree: "/wt/a", runState: .done, lifecycle: .seen)
        let shell = terminal(in: "/wt/a", session: chat)
        let rest = PilesLayout.place(piles([chat], terminals: [shell]), in: screen)
        let turned = PilesLayout.place(piles([chat], terminals: [shell]), in: screen, state: PilesState(front: .terminal(shell.id)))
        #expect(turned.frames[.terminal(shell.id)] == rest.frames[.session(chat.id)])
        #expect(turned.targets == [.terminal(shell.id)])
        #expect(turned.rings.values.first == [.session(chat.id), .terminal(shell.id)])
    }

    // MARK: Branches

    @Test func aTilesBranchDropsItsPrefixesAndHidesOnTheDefault() {
        var session = makeSession()
        for (branch, label) in [("ashley/fix-login", "fix-login"), ("constellation/fix-login", "fix-login"),
                                ("ashley/constellation/fix-login", "fix-login"), ("fix-login", "fix-login"), ("main", nil), ("", nil)] {
            session.branch = branch
            #expect(session.shortBranch(defaultBranch: "main") == label, "\(branch)")
        }
    }

    // MARK: Fans

    @Test func aFannedPileBloomsUprightRoundWhereItSat() {
        let chat = makeSession(worktree: "/wt/a", runState: .done, lifecycle: .seen)
        let shells = (0..<4).map { terminal(in: "/wt/a", session: chat, createdAt: t0 + Double($0)) }
        let desktop = piles([chat], terminals: shells)
        let id = desktop[0].id
        let layout = PilesLayout.place(desktop, in: screen, state: PilesState(fannedPile: id))
        let fanned = layout.cards.filter { $0.pile == id }
        #expect(fanned.allSatisfy { $0.role == .fanned && $0.frame.size == PileMetrics.card && $0.rotation == 0 })
        #expect(fanned.allSatisfy { screen.contains($0.frame) })
        #expect(layout.targets == [.session(chat.id)] + shells.map { .terminal($0.id) })
        #expect(layout.labels.first { $0.pile == id }?.isShown == false)
        // The rest ring the top card: none overlap, and they sit on every side of it.
        for a in fanned { for b in fanned where a.item != b.item { #expect(!a.frame.intersects(b.frame)) } }
        // Five make a plus: one each side of the top card, one above and one below.
        let middle = fanned[0].frame
        #expect(fanned[1].frame.maxX < middle.minX && fanned[1].frame.midY == middle.midY)
        #expect(fanned[2].frame.minX > middle.maxX && fanned[2].frame.midY == middle.midY)
        #expect(fanned[3].frame.maxY < middle.minY && fanned[3].frame.midX == middle.midX)
        #expect(fanned[4].frame.minY > middle.maxY && fanned[4].frame.midX == middle.midX)
    }

    @Test func aBigSpreadAtALargeScaleStaysOnScreen() {
        let frames = PilesLayout.pileFan(count: 28, around: CGPoint(x: screen.midX, y: screen.minY), in: screen, cardScale: 1.6)
        #expect(frames.allSatisfy { screen.contains($0) })
        for a in frames { for b in frames where a != b { #expect(!a.intersects(b)) } }
        let spread = PilesLayout.pileSpread(count: 5, around: CGPoint(x: screen.midX, y: screen.midY), in: screen, cardScale: 1.4)
        #expect(spread[0].frame.width >= PileMetrics.card.width * 1.4 * 0.8)
    }

    @Test func threeSpreadInARowAndSevenInAnAsterisk() {
        let centre = CGPoint(x: screen.midX, y: screen.midY)
        let three = PilesLayout.pileSpread(count: 3, around: centre, in: screen).map(\.frame)
        #expect(Set(three.map(\.midY)).count == 1 && three[1].maxX < three[0].minX && three[2].minX > three[0].maxX)
        let seven = PilesLayout.pileSpread(count: 7, around: centre, in: screen).map(\.frame)
        for a in seven { for b in seven where a != b { #expect(!a.intersects(b)) } }
        #expect(seven.allSatisfy { $0.size == PileMetrics.card })
    }

    @Test func aWidePileFanWrapsAndStaysOnScreen() {
        let frames = PilesLayout.pileFan(count: 9, around: CGPoint(x: screen.maxX, y: screen.maxY), in: screen)
        #expect(frames.allSatisfy { screen.insetBy(dx: -0.5, dy: -0.5).contains($0) })
        #expect(Set(frames.map(\.minY)).count == 2)
    }

    @Test func hoveringSpreadsThePileIntoFullCardsLikeAFan() {
        let chat = makeSession(worktree: "/wt/a", runState: .done, lifecycle: .seen)
        let shell = terminal(in: "/wt/a", session: chat)
        let desktop = piles([chat], terminals: [shell])
        let id = desktop[0].id
        let hovered = PilesLayout.place(desktop, in: screen, state: PilesState(hovered: id))
        let fanned = PilesLayout.place(desktop, in: screen, state: PilesState(fannedPile: id))
        #expect(hovered.frames == fanned.frames)
        let (a, b) = (hovered.frames[.session(chat.id)]!, hovered.frames[.terminal(shell.id)]!)
        #expect(a.width == PileMetrics.card.width)
        #expect(!a.intersects(b))
    }

    /// A card dragged in a spread pile lands in the place of the card nearest where it's dropped.
    @Test func aCardDroppedOnAnothersPlaceTakesIt() {
        let chat = makeSession(worktree: "/wt/a", runState: .done, lifecycle: .seen)
        let shells = (0..<3).map { terminal(in: "/wt/a", session: chat, createdAt: t0 + Double($0)) }
        let desktop = piles([chat], terminals: shells)
        let id = desktop[0].id
        let spread = PilesLayout.place(desktop, in: screen, state: PilesState(fannedPile: id))
        let from = spread.frames[.session(chat.id)]!, to = spread.frames[.terminal(shells[2].id)]!
        let offset = CGVector(dx: to.midX - from.midX + 10, dy: to.midY - from.midY)
        let dragged = PilesLayout.place(desktop, in: screen, state: PilesState(fannedPile: id, drag: PileDrag(.card(.session(chat.id)), offset: offset)))
        #expect(dragged.dropIndex(of: .session(chat.id), by: offset) == 3)
        let nudge = CGVector(dx: 5, dy: 5)
        let nudged = PilesLayout.place(desktop, in: screen, state: PilesState(fannedPile: id, drag: PileDrag(.card(.session(chat.id)), offset: nudge)))
        #expect(nudged.dropIndex(of: .session(chat.id), by: nudge) == 0)
    }
}

private struct PileRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uuid() -> UUID {
        let (a, b) = (next(), next())
        return withUnsafeBytes(of: (a, b)) { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

}
