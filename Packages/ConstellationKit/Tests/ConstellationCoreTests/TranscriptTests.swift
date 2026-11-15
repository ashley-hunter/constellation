import Foundation
import Testing
@testable import ConstellationCore

@Suite struct TranscriptTests {
    @Test func foldsConsecutiveToolCallsIntoOneEntry() {
        let transcript = Transcript([
            .userMessage("Fix the flaky test"),
            .toolCall(ToolCall(id: "1", name: "Bash", summary: "npm test")),
            .toolResult(ToolResult(toolCallID: "1", summary: "1 failed", isError: true)),
            .toolCall(ToolCall(id: "2", name: "Edit", summary: "src/a.ts", files: ["src/a.ts"])),
            .toolCall(ToolCall(id: "3", name: "Write", summary: "src/b.ts", files: ["src/b.ts"])),
            .assistantText("Fixed it.", isFinal: true),
        ])
        #expect(transcript.entries.count == 3)
        guard case .tools(_, let steps) = transcript.entries[1] else {
            Issue.record("Expected a tool run")
            return
        }
        #expect(steps.count == 3)
        #expect(steps[0].result?.isError == true)
        #expect(transcript.lastWrittenFile == "src/b.ts")
    }

    @Test func streamingTextGivesWayToTheFinalMessage() {
        var transcript = Transcript()
        transcript.append(.assistantText("Hel", isFinal: false))
        transcript.append(.assistantText("lo", isFinal: false))
        #expect(transcript.streaming == "Hello")
        #expect(transcript.entries.isEmpty)
        transcript.append(.assistantText("Hello", isFinal: true))
        #expect(transcript.streaming.isEmpty)
        #expect(transcript.entries == [.assistant(id: 0, text: "Hello")])
    }

    @Test func textBetweenToolCallsStartsANewRun() {
        let transcript = Transcript([
            .toolCall(ToolCall(id: "1", name: "Read", summary: "a")),
            .assistantText("Now the tests.", isFinal: true),
            .toolCall(ToolCall(id: "2", name: "Read", summary: "b")),
        ])
        #expect(transcript.entries.map(\.id) == [0, 1, 2])
        guard case .tools(_, let steps) = transcript.entries[2] else {
            Issue.record("Expected a tool run")
            return
        }
        #expect(steps.map(\.call.summary) == ["b"])
    }

    @Test func failuresOutcomesAndInterruptionsAreKept() {
        let transcript = Transcript([
            .failed(.turnError, message: "Rate limited"),
            .interrupted,
            .outcome(Outcome(status: .succeeded, summary: "Shipped")),
            .runState(.done),
        ])
        #expect(transcript.entries == [
            .failure(id: 0, message: "Rate limited"),
            .interrupted(id: 1),
            .outcome(id: 2, Outcome(status: .succeeded, summary: "Shipped")),
        ])
    }
}
