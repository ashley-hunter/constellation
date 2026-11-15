import ConstellationCore
import Foundation
import GRDB
import Testing
@testable import ConstellationStore

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

private func makeProject(_ name: String = "orbit") -> Project {
    Project(name: name, rootPath: URL(filePath: "/tmp/\(name)"), swatch: .sage)
}

private func makeSession(in project: Project, title: String = "Fix login", runState: RunState = .working) -> Session {
    Session(
        projectID: project.id,
        provider: .claudeCode,
        model: "opus",
        title: title,
        worktreePath: URL(filePath: "/tmp/wt/\(UUID().uuidString)"),
        branch: "constellation/abcd1234",
        baseBranch: "main",
        createdAt: start,
        runState: runState
    )
}

private func permissionAsk(_ id: String, for session: Session, status: AskStatus = .pending) -> Ask {
    Ask(
        id: id,
        sessionID: session.id,
        kind: .permission(PermissionAsk(toolName: "Bash", summary: "npm test")),
        createdAt: start,
        status: status
    )
}

private func stored(_ event: SessionEvent, _ session: Session, _ sequence: Int) -> StoredEvent {
    StoredEvent(sessionID: session.id, sequence: sequence, time: start.addingTimeInterval(Double(sequence)), event: event)
}

@Suite struct StoreTests {
    let store: Store
    let project: Project

    init() throws {
        store = try Store.inMemory()
        project = makeProject()
        try store.save(project)
    }

    @Test func projectsRoundTripInOrderAdded() throws {
        var second = makeProject("nebula")
        second.setupScriptPath = URL(filePath: "/tmp/nebula/.constellation/setup.sh")
        second.defaultProvider = .codex
        try store.save(second)
        second.name = "Nebula"
        try store.save(second)

        #expect(try store.projects() == [project, second])
    }

    @Test func turnSettingsRoundTrip() throws {
        var session = makeSession(in: project)
        try store.save(session)
        #expect(try store.sessions().first?.turnSettings == session.turnSettings)

        session.model = "haiku"
        session.effort = "low"
        session.fastMode = true
        try store.save(session)
        #expect(try store.sessions() == [session])
    }

    @Test func sessionRoundTripsWithItsAsksInOrder() throws {
        var session = makeSession(in: project)
        session.nativeID = "native-1"
        session.lastSeenAt = start.addingTimeInterval(5)
        session.filesTouched = ["Sources/A.swift", "README.md"]
        session.outcome = Outcome(status: .succeeded, summary: "Tests pass")
        session.pullRequest = PullRequestInfo(
            number: 42,
            url: URL(string: "https://github.com/a/b/pull/42")!,
            state: .open,
            reviewDecision: .approved,
            checks: CheckSummary(state: .success, passed: 3, total: 3)
        )
        session.asks = [
            permissionAsk("b", for: session),
            Ask(id: "a", sessionID: session.id, kind: .secret(SecretAsk(name: "TOKEN", reason: "deploy")), createdAt: start),
            permissionAsk("c", for: session, status: .answered),
        ]
        try store.save(session)

        #expect(try store.sessions() == [session])

        session.asks.removeFirst()
        session.runState = .failed(.launch(.setup))
        session.failureMessage = "setup.sh exited 1"
        try store.save(session)
        #expect(try store.sessions() == [session])
    }

    @Test func archivedSessionsAreLeftOutUnlessAskedFor() throws {
        let live = makeSession(in: project, title: "live")
        var archived = makeSession(in: project, title: "archived", runState: .done)
        archived.lifecycle = .archived
        try store.save(live)
        try store.save(archived)

        #expect(try store.sessions().map(\.title) == ["live"])
        #expect(try Set(store.sessions(includingArchived: true).map(\.title)) == ["live", "archived"])
    }

    @Test func secretAsksAreStoredWithoutAnyValue() throws {
        var session = makeSession(in: project, runState: .blocked)
        session.asks = [Ask(id: "s", sessionID: session.id, kind: .secret(SecretAsk(name: "STRIPE_KEY", reason: "webhooks")))]
        try store.save(session)

        #expect(try store.sessions().first?.asks == session.asks)
    }

    @Test func terminalsRoundTripAndDeletingForgetsTheirPlace() throws {
        let session = makeSession(in: project)
        try store.save(session)
        let terminal = Terminal(
            projectID: project.id,
            workingDirectory: session.worktreePath,
            sessionID: session.id,
            title: "zsh",
            state: .running,
            lastExitCode: 1
        )
        try store.save(terminal)
        try store.savePosition(TilePosition(x: 10, y: 20), of: .terminal(terminal.id), in: .projects)
        let group = RelatedGroup(origin: .pinned(name: "Auth"), members: [.terminal(terminal.id), .session(session.id)])
        try store.save(group)

        let browser = Terminal(projectID: project.id, workingDirectory: project.rootPath, title: "localhost", url: URL(string: "http://localhost:5173/"))
        try store.save(browser)

        #expect(try store.terminals() == [terminal, browser])

        try store.deleteTerminal(browser.id)
        try store.deleteTerminal(terminal.id)
        #expect(try store.terminals().isEmpty)
        #expect(try store.positions(for: .projects).isEmpty)
        #expect(try store.pinnedGroups().first?.members == [.session(session.id)])
    }

    @Test func aNoteRoundTripsWithItsMarkdown() throws {
        let note = Terminal(projectID: project.id, workingDirectory: project.rootPath, title: "Plan", note: "# Plan\n\n- ship notes")
        try store.save(note)

        let restored = try #require(try store.terminals().first)
        #expect(restored == note)
        #expect(restored.isNote && !restored.isBrowser && !restored.isTask)
    }

    /// A store from before notes gains the column, its terminals coming back as shells.
    @Test func notesMigrateOntoAnOlderStore() throws {
        let url = URL.temporaryDirectory.appending(path: "notes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let shell = Terminal(projectID: project.id, workingDirectory: project.rootPath, title: "zsh", createdAt: start)
        let older = try DatabaseQueue(path: url.path(percentEncoded: false))
        try Schema.migrator.migrate(older, upTo: "v6-tasks")
        try older.write { db in
            try ProjectRecord(project).insert(db)
            try db.execute(
                sql: "INSERT INTO terminals (id, projectId, workingDirectory, title, state, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [shell.id.uuidString, project.id.uuidString, shell.workingDirectory.absoluteString, shell.title, shell.state.rawValue, start.timeIntervalSinceReferenceDate]
            )
        }
        try older.close()

        let store = try Store(url: url)
        let migrated = try #require(try store.terminals().first)
        #expect(migrated.id == shell.id && migrated.note == nil && !migrated.isNote)

        var note = migrated
        note.note = "Remember the release notes"
        try store.save(note)
        #expect(try Store(url: url).terminals() == [note])
    }

    /// A store from when plan mode existed loses its plan asks and their events but keeps the rest.
    @Test func planModeMigratesOffAnOlderStore() throws {
        let url = URL.temporaryDirectory.appending(path: "plans-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = makeSession(in: project, runState: .blocked)
        let kept = stored(.askRaised(permissionAsk("b", for: session)), session, 2)
        let older = try DatabaseQueue(path: url.path(percentEncoded: false))
        try Schema.migrator.migrate(older, upTo: "v7-notes")
        try older.write { db in
            try ProjectRecord(project).insert(db)
            try SessionRecord(session).insert(db)
            try db.execute(sql: "INSERT INTO session_turn_settings (sessionId, fastMode, planMode) VALUES (?, 1, 1)", arguments: [session.id.uuidString])
            let plan = #"{"plan":{"_0":{"markdown":"Ship it"}}}"#
            try db.execute(
                sql: "INSERT INTO asks (id, sessionId, position, kind, createdAt, status) VALUES ('p', ?, 0, ?, 0, 'pending')",
                arguments: [session.id.uuidString, plan]
            )
            let raised = #"{"askRaised":{"_0":{"id":"p","sessionID":"\#(session.id.uuidString)","kind":\#(plan),"createdAt":0,"status":"pending"}}}"#
            try db.execute(
                sql: "INSERT INTO events (sessionId, sequence, time, kind, payload) VALUES (?, 1, 0, 'askRaised', ?)",
                arguments: [session.id.uuidString, raised]
            )
            try EventRecord(kept).insert(db)
        }
        try older.close()

        let store = try Store(url: url)
        let restored = try #require(try store.sessions().first)
        #expect(restored.asks.isEmpty && restored.fastMode)
        #expect(try store.events(for: session.id) == [kept])
    }

    @Test func positionsAreKeptPerArrangementAndReset() throws {
        let item = TileItem.session(UUID())
        try store.savePosition(TilePosition(x: 1, y: 2), of: item, in: .projects)
        try store.savePosition(TilePosition(x: 3, y: 4), of: item, in: .projects)
        try store.savePosition(TilePosition(x: 5, y: 6), of: item, in: .related)

        #expect(try store.positions(for: .projects) == [item: TilePosition(x: 3, y: 4)])

        try store.resetPositions(for: .projects)
        #expect(try store.positions(for: .projects).isEmpty)
        #expect(try store.positions(for: .related) == [item: TilePosition(x: 5, y: 6)])
    }

    @Test func onlyPinnedGroupsComeBack() throws {
        let members: Set<TileItem> = [.session(UUID()), .terminal(UUID())]
        var pinned = RelatedGroup(origin: .pinned(name: "Payments"), members: members)
        try store.save(pinned)
        try store.save(RelatedGroup(origin: .inferred(.sharedBaseBranch("feature/x")), members: members))

        #expect(try store.pinnedGroups() == [pinned])

        pinned.origin = .pinned(name: "Billing")
        pinned.members.removeFirst()
        try store.save(pinned)
        #expect(try store.pinnedGroups() == [pinned])

        try store.deleteGroup(pinned.id)
        #expect(try store.pinnedGroups().isEmpty)
    }

    @Test func settingsCanBeSetChangedAndRemoved() throws {
        #expect(try store.setting("cleanupThreshold") == nil)
        try store.setSetting("cleanupThreshold", to: "1d")
        try store.setSetting("cleanupThreshold", to: "1w")
        #expect(try store.setting("cleanupThreshold") == "1w")
        try store.setSetting("cleanupThreshold", to: nil)
        #expect(try store.setting("cleanupThreshold") == nil)
    }

    @Test func eventsComeBackInSequenceOrder() throws {
        let session = makeSession(in: project)
        try store.save(session)
        let events = [
            stored(.started(nativeID: "abc"), session, 1),
            stored(.userMessage("Fix the login bug"), session, 2),
            stored(.toolCall(ToolCall(id: "t1", name: "Edit", summary: "Login.swift", files: ["Login.swift"])), session, 3),
            stored(.runState(.done), session, 4),
        ]
        try store.append(Array(events[2...]))
        try store.append(Array(events[..<2]))

        #expect(try store.events(for: session.id) == events)
        #expect(try store.lastSequence(for: session.id) == 4)
        #expect(try store.lastSequence(for: UUID()) == nil)
    }

    @Test func deletingAProjectRemovesEverythingUnderIt() throws {
        let session = makeSession(in: project)
        try store.save(session)
        try store.append([stored(.userMessage("refactor the parser"), session, 1)])
        try store.savePosition(TilePosition(x: 0, y: 0), of: .session(session.id), in: .attention)
        #expect(try store.sessionIDs(inProject: project.id) == [session.id])

        try store.deleteProject(project.id)

        #expect(try store.projects().isEmpty)
        #expect(try store.sessions(includingArchived: true).isEmpty)
        #expect(try store.events(for: session.id).isEmpty)
        #expect(try store.search("parser").isEmpty)
        #expect(try store.positions(for: .attention).isEmpty)
    }
}

@Suite struct SearchTests {
    let store: Store
    let project: Project

    init() throws {
        store = try Store.inMemory()
        project = makeProject()
        try store.save(project)
    }

    @Test func findsMessagesAndToolSummariesInEverySessionIncludingArchived() throws {
        let first = makeSession(in: project, title: "one")
        var second = makeSession(in: project, title: "two", runState: .done)
        second.lifecycle = .archived
        let third = makeSession(in: project, title: "three")
        try [first, second, third].forEach(store.save)
        try store.append([
            stored(.userMessage("Please fix the webhook retries"), first, 1),
            stored(.assistantText("Looking at the webhook handler now.", isFinal: true), first, 2),
            stored(.toolCall(ToolCall(id: "1", name: "Bash", summary: "grep -rn webhook Sources")), second, 1),
            stored(.toolResult(ToolResult(toolCallID: "1", summary: "Found 3 webhook handlers")), second, 2),
            stored(.userMessage("Update the README"), third, 1),
        ])

        let hits = try store.search("webhook")
        #expect(Set(hits.map(\.sessionID)) == [first.id, second.id])
        #expect(hits.count == 2)
        #expect(try store.search("readme").map(\.sessionID) == [third.id])
    }

    @Test func matchesWordPrefixesAndHighlightsThem() throws {
        let session = makeSession(in: project)
        try store.save(session)
        try store.append([stored(.assistantText("The migration renamed the column safely.", isFinal: true), session, 7)])

        let hit = try #require(try store.search("migrat colu").first)
        #expect(hit.sequence == 7)
        #expect(hit.snippet == "The migration renamed the column safely.")
        #expect(hit.highlights.map { String(hit.snippet[$0]) } == ["migration", "column"])
    }

    @Test func ignoresEventsWithoutText() throws {
        let session = makeSession(in: project)
        try store.save(session)
        let ask = Ask(id: "q", sessionID: session.id, kind: .secret(SecretAsk(name: "DEPLOY_KEY", reason: "deploy")))
        try store.append([
            stored(.askRaised(ask), session, 1),
            stored(.outcome(Outcome(status: .succeeded, summary: "deploy done")), session, 2),
        ])

        #expect(try store.search("deploy").isEmpty)
    }

    @Test func queryPunctuationIsNotSyntax() throws {
        let session = makeSession(in: project)
        try store.save(session)
        try store.append([stored(.userMessage("why does \"auth\" fail? (again)"), session, 1)])

        #expect(try store.search("\"auth\" (fail").count == 1)
        #expect(try store.search("   ").isEmpty)
        #expect(try store.search("NOT OR AND *").isEmpty)
    }
}

@Suite struct RestartTests {
    @Test func liveSessionsAreInterruptedAndPendingAsksExpire() throws {
        let store = try Store.inMemory()
        let project = makeProject()
        try store.save(project)

        var blocked = makeSession(in: project, title: "blocked", runState: .blocked)
        blocked.asks = [permissionAsk("p1", for: blocked, status: .answered), permissionAsk("p2", for: blocked)]
        let working = makeSession(in: project, title: "working", runState: .working)
        let done = makeSession(in: project, title: "done", runState: .done)
        let launching = makeSession(in: project, title: "launching", runState: .preparing(.setup))
        var archived = makeSession(in: project, title: "archived", runState: .working)
        archived.lifecycle = .archived
        try [blocked, working, done, launching, archived].forEach(store.save)
        try store.save(Terminal(projectID: project.id, workingDirectory: project.rootPath, title: "zsh"))
        try store.setSetting("arrangement", to: "related")

        let restored = try store.restoreAtLaunch()
        let byTitle = Dictionary(uniqueKeysWithValues: restored.sessions.map { ($0.title, $0) })

        #expect(byTitle["blocked"]?.runState == .interrupted)
        #expect(byTitle["blocked"]?.asks.map(\.status) == [.answered, .expired])
        #expect(byTitle["working"]?.runState == .interrupted)
        #expect(byTitle["done"]?.runState == .done)
        #expect(byTitle["launching"]?.runState == .failed(.launch(.setup)))
        #expect(byTitle["archived"] == nil)
        #expect(try store.sessions(includingArchived: true).first { $0.id == archived.id }?.runState == .working)
        #expect(restored.projects == [project])
        #expect(restored.terminals.count == 1)
        #expect(restored.settings == ["arrangement": "related"])
        #expect(try store.loadAll().sessions == restored.sessions)
    }

    @Test func sessionsThatWereLiveResumeAndStoppedOnesStayInterrupted() throws {
        let store = try Store.inMemory()
        let project = makeProject()
        try store.save(project)

        var working = makeSession(in: project, title: "working", runState: .working)
        working.nativeID = "n1"
        var blocked = makeSession(in: project, title: "blocked", runState: .blocked)
        blocked.nativeID = "n2"
        blocked.asks = [permissionAsk("p1", for: blocked)]
        var stopped = makeSession(in: project, title: "stopped", runState: .interrupted)
        stopped.nativeID = "n3"
        var archived = makeSession(in: project, title: "archived", runState: .working)
        archived.nativeID = "n4"
        archived.lifecycle = .archived
        let unnamed = makeSession(in: project, title: "unnamed", runState: .working)
        try [working, blocked, stopped, archived, unnamed].forEach(store.save)

        let restored = try store.restoreAtLaunch()
        let resumed = Dictionary(uniqueKeysWithValues: restored.resumes.map { ($0.sessionID, $0.kind) })
        #expect(resumed.count == 2)
        #expect(resumed[working.id] == .midTurn)
        guard case .waiting(let ask)? = resumed[blocked.id] else {
            Issue.record("The blocked session should resume waiting")
            return
        }
        #expect(ask?.id == "p1")
        // The restart rule interrupts them all first; the app resumes from there.
        #expect(restored.sessions.allSatisfy { $0.runState == .interrupted })
    }

    @Test func aFileStoreKeepsItsDataAcrossOpens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "constellation-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "constellation.sqlite")
        let project = makeProject()
        let session = makeSession(in: project)

        do {
            let store = try Store(url: url)
            try store.save(project)
            try store.save(session)
            try store.append([stored(.userMessage("persist me"), session, 1)])
        }

        let reopened = try Store(url: url)
        #expect(try reopened.projects() == [project])
        #expect(try reopened.restoreAtLaunch().sessions.map(\.runState) == [.interrupted])
        #expect(try reopened.search("persist").map(\.sessionID) == [session.id])
    }
}

@Suite struct EventRecorderTests {
    let store: Store
    let session: Session

    init() throws {
        store = try Store.inMemory()
        let project = makeProject()
        try store.save(project)
        session = makeSession(in: project)
        try store.save(session)
    }

    @Test func numbersEventsAndWritesThemOnFlush() async throws {
        let recorder = EventRecorder(store: store, interval: .seconds(60))
        let first = await recorder.record(.userMessage("hello"), for: session.id)
        let second = await recorder.record(.assistantText("hi", isFinal: true), for: session.id)
        #expect(first == 1)
        #expect(second == 2)
        #expect(try store.events(for: session.id).isEmpty)

        try await recorder.flush()
        #expect(try store.events(for: session.id).map(\.sequence) == [1, 2])
    }

    @Test func continuesNumberingFromStoredEvents() async throws {
        try store.append([stored(.userMessage("earlier"), session, 41)])
        let recorder = EventRecorder(store: store)

        #expect(await recorder.record(.userMessage("later"), for: session.id) == 42)
    }

    @Test func writesOnItsOwnAfterTheInterval() async throws {
        let recorder = EventRecorder(store: store, interval: .milliseconds(50))
        for index in 0..<5 {
            await recorder.record(.userMessage("message \(index)"), for: session.id)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while try store.events(for: session.id).count < 5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try store.events(for: session.id).count == 5)
    }

    @Test func keepsEventsQueuedWhenTheWriteFails() async throws {
        let recorder = EventRecorder(store: store, interval: .seconds(60))
        let orphan = UUID()
        await recorder.record(.userMessage("no such session"), for: orphan)

        await #expect(throws: (any Error).self) { try await recorder.flush() }
        try store.save(Session(
            id: orphan,
            projectID: session.projectID,
            provider: .codex,
            model: "gpt",
            title: "late",
            worktreePath: session.worktreePath,
            branch: "b",
            baseBranch: "main"
        ))
        try await recorder.flush()
        #expect(try store.events(for: orphan).count == 1)
    }
}

@Suite struct QueueTests {
    @Test func queuesRoundTripInOrderAndArchivedSessionsAreLeftOut() throws {
        let store = try Store.inMemory()
        let project = makeProject()
        try store.save(project)
        let session = makeSession(in: project)
        var archived = makeSession(in: project, title: "Old")
        archived.lifecycle = .archived
        try store.save(session)
        try store.save(archived)

        let image = Attachment(name: "a.png", kind: .image, mimeType: "image/png", byteCount: 3, storedURL: URL(filePath: "/tmp/a.png"))
        let queue = [
            QueuedMessage(sessionID: session.id, message: UserMessage(text: "first", attachments: [image]), createdAt: start),
            QueuedMessage(sessionID: session.id, message: UserMessage(text: "second"), createdAt: start),
        ]
        try store.saveQueue(queue, for: session.id)
        try store.saveQueue([QueuedMessage(sessionID: archived.id, message: UserMessage(text: "never"))], for: archived.id)
        #expect(try store.queuedMessages() == queue)
        #expect(try store.restoreAtLaunch().queuedMessages == queue)

        try store.saveQueue(queue.reversed(), for: session.id)
        #expect(try store.queuedMessages().map(\.message.text) == ["second", "first"])
        try store.saveQueue([], for: session.id)
        #expect(try store.queuedMessages().isEmpty)
    }
}

@Suite struct PromptHistoryStoreTests {
    @Test func keepsEachProjectsPromptsNewestFirstWithoutRepeats() throws {
        let store = try Store.inMemory()
        let (project, other) = (makeProject(), makeProject("nebula"))
        try store.save(project)
        try store.save(other)

        for text in ["first", "second", "  first  ", ""] {
            try store.recordPrompt(text, for: project.id)
        }
        try store.recordPrompt("elsewhere", for: other.id)

        #expect(try store.promptHistory(for: project.id) == ["first", "second"])
        #expect(try store.promptHistory(for: project.id, limit: 1) == ["first"])
        #expect(try store.promptHistory(for: other.id) == ["elsewhere"])

        try store.deleteProject(other.id)
        #expect(try store.promptHistory(for: other.id).isEmpty)
    }
}

@Suite struct PaletteRecentsStoreTests {
    @Test func keepsKeysNewestFirstWithoutRepeats() throws {
        let store = try Store.inMemory()
        for (offset, key) in ["git.commit", "arrange.by:2", "git.commit"].enumerated() {
            try store.recordPaletteUse(key, at: start.addingTimeInterval(Double(offset)))
        }
        #expect(try store.paletteRecents() == ["git.commit", "arrange.by:2"])
        #expect(try store.paletteRecents(limit: 1) == ["git.commit"])
    }

    @Test func dropsTheOldestPastTheLimit() throws {
        let store = try Store.inMemory()
        for index in 0...PaletteRanking.recentsLimit {
            try store.recordPaletteUse("key\(index)", at: start.addingTimeInterval(Double(index)))
        }
        let recents = try store.paletteRecents(limit: 500)
        #expect(recents.count == PaletteRanking.recentsLimit)
        #expect(recents.first == "key\(PaletteRanking.recentsLimit)")
        #expect(!recents.contains("key0"))
    }
}
