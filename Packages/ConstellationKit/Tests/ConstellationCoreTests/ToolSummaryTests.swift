import Testing
@testable import ConstellationCore

@Suite struct ToolSummaryTests {
    @Test func countsEachKindInPlainWords() {
        #expect(ToolCall.summary(of: [.command, .read, .command]) == "Ran 2 commands, read 1 file")
        #expect(ToolCall.summary(of: [.search]) == "Searched 1 time")
        #expect(ToolCall.summary(of: [.edit, .other, .other]) == "Edited 1 file, used 2 tools")
    }
}
