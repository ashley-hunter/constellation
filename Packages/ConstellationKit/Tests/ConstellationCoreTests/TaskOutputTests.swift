import Testing
@testable import ConstellationCore

@Suite struct TaskOutputTests {
    @Test func picksTheFailingTestAndWhatItExpected() {
        let output = "\u{1B}[32m✓\u{1B}[0m formats pounds\n\u{1B}[31m✗ rounds each line to the penny\u{1B}[0m\n  Expected 0.26, received 0.25\n\nTests 1 failed\n➜ repo git:(main) ✗ "
        #expect(TaskOutput.failureLines(output) == ["✗ rounds each line to the penny", "Expected 0.26, received 0.25", "Tests 1 failed"])
    }

    @Test func readsATerminalsCarriageReturnLineFeeds() {
        let output = "\u{1B}]133;C\u{07}> sh test.sh\r\n\r\n✗ rounds each line to the penny\r\n  Expected 0.26\r\n\u{1B}[1m%\u{1B}[0m   \r \r\u{1B}]133;D;1\u{07}➜  repo \u{1B}="
        #expect(TaskOutput.failureLines(output) == ["✗ rounds each line to the penny", "Expected 0.26"])
    }

    @Test func fallsBackToTheLastLinesAndKeepsOnlyARedrawsEnd() {
        let output = "building\r 10%\r 100%\nsegfault in worker\n➜ repo "
        #expect(TaskOutput.failureLines(output, limit: 2) == ["100%", "segfault in worker"])
    }
}
