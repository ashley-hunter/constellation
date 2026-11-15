import ConstellationCore
import Foundation
import Testing
@testable import ConstellationStore

@Suite struct DraftStoreTests {
    let store: Store
    let project: Project
    let draft: Session

    init() throws {
        store = try Store.inMemory()
        project = Project(name: "orbit", rootPath: URL(filePath: "/tmp/orbit"), swatch: .sage)
        try store.save(project)
        var draft = Session(
            projectID: project.id,
            provider: .claudeCode,
            model: "sonnet",
            title: "New session",
            worktreePath: project.rootPath,
            branch: "",
            baseBranch: "main",
            runState: .draft
        )
        draft.fastMode = true
        self.draft = draft
    }

    @Test func aDraftAndItsMessageSurviveARestart() throws {
        try store.saveDraft(draft, message: UserMessage(text: "Fix the login form"))

        let restored = try store.restoreAtLaunch()
        #expect(restored.sessions.map(\.runState) == [.draft])
        #expect(restored.sessions.first?.fastMode == true)
        #expect(try store.draftMessages() == [draft.id: UserMessage(text: "Fix the login form")])
    }

    @Test func savingAgainReplacesTheMessage() throws {
        try store.saveDraft(draft, message: UserMessage(text: "Fix"))
        try store.saveDraft(draft, message: UserMessage(text: "Fix the login form"))
        #expect(try store.draftMessages()[draft.id]?.text == "Fix the login form")
    }

    @Test func deletingADraftRemovesItsMessageAndPosition() throws {
        try store.saveDraft(draft, message: UserMessage(text: "Fix"))
        try store.savePosition(TilePosition(x: 10, y: 20), of: .session(draft.id), in: .projects)

        try store.deleteSession(draft.id)

        #expect(try store.sessions().isEmpty)
        #expect(try store.draftMessages().isEmpty)
        #expect(try store.positions(for: .projects).isEmpty)
    }

    @Test func launchingClearsTheMessageAndKeepsTheSession() throws {
        try store.saveDraft(draft, message: UserMessage(text: "Fix"))
        var launched = draft
        launched.runState = .preparing(.fetch)
        try store.save(launched)
        try store.clearDraftMessage(for: draft.id)

        #expect(try store.draftMessages().isEmpty)
        #expect(try store.sessions().map(\.id) == [draft.id])
    }
}
