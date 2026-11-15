import Foundation
import Testing
@testable import ConstellationCore

@Suite struct NoteTextTests {
    @Test func aNoteIsATerminalWithMarkdown() {
        let note = Terminal(projectID: projectA, workingDirectory: URL(filePath: "/repo"), title: "", note: "")
        #expect(note.isNote && !note.isBrowser && !note.isTask)
        #expect(!Terminal(projectID: projectA, workingDirectory: URL(filePath: "/repo"), title: "zsh").isNote)
    }

    @Test func theTitleIsTheFirstLineWithoutItsHeadingMarks() {
        #expect(NoteText.title(of: "\n## Release plan\nbody") == "Release plan")
        #expect(NoteText.title(of: "#Ideas") == "Ideas")
        #expect(NoteText.title(of: "  \n") == nil)
        #expect(NoteText.title(of: "#") == nil)
    }

    @Test func thePreviewIsTheNextLinesAsPlainText() {
        let text = "# Plan\n\n- [ ] **ship** the card\n1. write _tests_\n> quoted `code`\n### Later"
        #expect(NoteText.preview(of: text) == "ship the card\nwrite tests\nquoted code\nLater")
        #expect(NoteText.preview(of: text, limit: 1) == "ship the card")
        #expect(NoteText.preview(of: "# Only a title").isEmpty)
    }
}
