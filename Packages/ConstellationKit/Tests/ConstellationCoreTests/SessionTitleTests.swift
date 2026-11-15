import Testing
@testable import ConstellationCore

@Suite struct SessionTitleTests {
    @Test(arguments: [
        ("Add a GET /products/:id endpoint to server.js that returns 404 when the product doesn't exist", "GET /products/:id endpoint"),
        ("Add a delete command for notes", "Delete command for notes"),
        ("Please can you fix the flaky test in PilesTests.swift, it fails on CI", "Fix flaky test"),
        ("I want to rename the `user_id` column to `account_id` everywhere", "Rename `user_id` column"),
        ("Hey, so the build is broken after the last merge. Can you look into it?", "Build is broken"),
        ("Can you make the sidebar collapsible?", "Make sidebar collapsible"),
        ("Write tests for the \"export notes\" command", "Write tests for \"export notes\""),
        ("refactor useSessionStore so it doesn't re-render on every keystroke", "Refactor useSessionStore"),
        ("Create a new CLI flag --dry-run that prints what would change", "New CLI flag --dry-run"),
    ])
    func namesTheChange(prompt: String, title: String) {
        #expect(SessionTitle.make(from: prompt) == title)
    }

    @Test func staysShort() {
        let title = SessionTitle.make(from: "Migrate the whole persistence layer over from Core Data to SQLite with GRDB and keep the old data")
        #expect(title.count <= 32)
        #expect(title.split(separator: " ").count <= 5)
    }

    @Test func fallsBackForAnEmptyOrFillerPrompt() {
        #expect(SessionTitle.make(from: "") == "New session")
        #expect(SessionTitle.make(from: "   \n") == "New session")
        #expect(SessionTitle.make(from: "Please") == "Please")
    }

    @Test func labelBranchDropsPrefixAndRequestWords() {
        #expect(Session.labelBranch("constellation/add-a-get-products-id", defaultBranch: "main") == "get-products-id")
        #expect(Session.labelBranch("ashley/fix-login", defaultBranch: "main") == "fix-login")
        #expect(Session.labelBranch("add-a", defaultBranch: "main") == nil)
        #expect(Session.labelBranch("main", defaultBranch: "main") == nil)
    }
}
