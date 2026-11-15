import Testing
@testable import ConstellationCore

@Suite struct QuestionPromptTests {
    @Test func questionsAreQuestions() {
        let questions = [
            "What does server.js do?",
            "Run python3 notes.py list and tell me the output",
            "why is the build slow",
            "How do sessions get their port",
            "Where is the keymap loaded",
            "Is this thread safe",
            "Does the store migrate old rows",
            "Can you check the tests pass",
            "Explain the launch stages",
            "Describe the draft panel",
            "Show me where drafts are saved",
            "tell me about the git service",
            "Summarise the README",
            "Summarize recent changes",
            "List the TODOs in App/",
            "Find every caller of startDraft",
            "Review the diff on this branch",
            "Run the tests and show me what fails",
            "Read Keymap.swift and explain the sequencer",
            "Add a button?",
            "  which file owns the palette  \n",
        ]
        for prompt in questions {
            #expect(QuestionPrompt.isQuestion(prompt), "\(prompt)")
        }
    }

    @Test func tasksAreNot() {
        let tasks = [
            "Add a dark mode toggle to settings",
            "Fix the crash when a draft is discarded",
            "Refactor AppModel+Launch into smaller pieces",
            "Run python3 notes.py add milk",
            "Isolate the flaky test",
            "Update the README with explaining comments",
            "Write tests for the reducer",
            "",
            "   ",
        ]
        for prompt in tasks {
            #expect(!QuestionPrompt.isQuestion(prompt), "\(prompt)")
        }
    }
}
