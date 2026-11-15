import Foundation
import Testing
@testable import ConstellationCore

@Suite struct LiveOutputTests {
    private func output(_ events: SessionEvent...) -> LiveOutput {
        var output = LiveOutput()
        for event in events { output.append(event) }
        return output
    }

    private let failedBash: [SessionEvent] = [
        .toolCall(ToolCall(id: "1", name: "Bash", summary: "npm test")),
        .toolResult(ToolResult(toolCallID: "1", summary: "Exit code 254", isError: true)),
    ]

    @Test func aFailureThatRepeatsTheLastLineShowsOnce() {
        var output = LiveOutput()
        for event in failedBash { output.append(event) }
        output.append(.failed(.turnError, message: "Exit code 254"))
        #expect(output.lines.map(\.text) == ["$ npm test", "  Exit code 254"])
        #expect(output.lines.last?.tone == .error)
        #expect(output.showsFailure)
    }

    @Test func theProcessExitAfterAFailureAddsNothing() {
        let output = output(
            .userMessage("go"),
            .failed(.processExited, message: "Claude Code exited with code 254"),
            .exited(code: 254)
        )
        #expect(output.lines.map(\.text) == ["› go", "Claude Code exited with code 254"])
    }

    @Test func anExitWithNoFailureReportedShowsOnce() {
        let output = output(.userMessage("go"), .exited(code: 254))
        #expect(output.lines.map(\.text) == ["› go", "Exited with code 254"])
        #expect(output.showsFailure)
    }

    @Test func aReportedFailureCountsAsShown() {
        let output = output(.outcome(Outcome(status: .failed, summary: "Tests still fail")))
        #expect(output.showsFailure)
    }

    @Test func theNextTurnCanFailAgain() {
        let output = output(
            .failed(.turnError, message: "Rate limited"),
            .userMessage("retry"),
            .failed(.turnError, message: "Rate limited")
        )
        #expect(output.lines.map(\.text) == ["Rate limited", "› retry", "Rate limited"])
    }

    @Test func onlyTheLastLineOfAMultilineFailureShows() {
        let output = output(.failed(.turnError, message: "Error:\nExit code 254\n"))
        #expect(output.lines.map(\.text) == ["Exit code 254"])
    }

    @Test func keepsTheNewestLinesAndTheStreamingTextLast() {
        var output = LiveOutput()
        for index in 0..<20 { output.append(.assistantText("line \(index)", isFinal: true)) }
        output.append(.assistantText("partial\nnewest", isFinal: false))
        #expect(output.lines.count == LiveOutput.capacity)
        #expect(output.tail(2).map(\.text) == ["line 19", "newest"])
    }

    // MARK: Activity

    @Test func activitySaysTheLatestToolCallInWords() {
        let output = output(
            .userMessage("fix login"),
            .toolCall(ToolCall(id: "1", name: "Read", summary: "Sources/App/LoginView.swift")),
            .toolCall(ToolCall(id: "2", name: "mcp__constellation__report_outcome", summary: "report")),
            .toolCall(ToolCall(id: "3", name: "Bash", summary: "swift test --filter LoginTests --parallel --verbose"))
        )
        #expect(output.activity == "Running `swift test --filter LoginTests --parall…`")
    }

    @Test func constellationsOwnToolsAreNeverAnActivity() {
        let output = output(
            .toolCall(ToolCall(id: "1", name: "Edit", summary: "LoginView.swift")),
            .toolCall(ToolCall(id: "2", name: "mcp__constellation__report_outcome", summary: "report"))
        )
        #expect(output.activity == "Editing LoginView.swift")
    }

    @Test func aFinishedReplyClearsTheActivityAndIsKept() {
        let output = output(
            .toolCall(ToolCall(id: "1", name: "Edit", summary: "LoginView.swift")),
            .assistantText("Done.\nHello, Ashley!", isFinal: true)
        )
        #expect(output.activity == nil)
        #expect(output.lastReply == "Hello, Ashley!")
    }

    @Test func toolCallsReadAsWords() {
        #expect(ToolCall(id: "", name: "Write", summary: "a/b/c.md").activity == "Writing c.md")
        #expect(ToolCall(id: "", name: "Grep", summary: "TODO").activity == "Searching for TODO")
        #expect(ToolCall(id: "", name: "apply_patch", summary: "Edit x", files: ["a/x.swift", "y.swift"]).activity == "Editing x.swift, y.swift")
        #expect(ToolCall(id: "", name: "mcp__github__create_pull_request", summary: "").activity == "Using create pull request in github")
        #expect(ToolCall(id: "", name: "WebFetch", summary: "https://swift.org/docs").activity == "Reading swift.org")
        #expect(ToolCall(id: "", name: "TodoWrite", summary: "").activity == "Updating its plan")
    }

    @Test func traceLinesSayWhatACallDidWithTheObjectApart() {
        let grep = ToolCall(id: "", name: "Grep", summary: "minimumReleaseAge").phrase
        #expect(grep?.kind == .search)
        #expect(grep?.past == "Searched for")
        #expect(grep?.object == "minimumReleaseAge")
        let bash = ToolCall(id: "", name: "Bash", summary: "swift test --filter LoginTests --parallel --verbose").phrase
        #expect(bash?.past == "Ran")
        #expect(bash?.object == "swift test --filter LoginTests --parallel --verbose")
        #expect(ToolCall(id: "", name: "Edit", summary: "Sources/LoginView.swift").phrase?.past == "Edited")
        #expect(ToolCall(id: "", name: "mcp__constellation__report_outcome", summary: "").phrase == nil)
    }
}
