import Foundation
import Testing
@testable import ConstellationCore

@Suite struct ShellMarkScannerTests {
    private func scan(_ chunks: String...) -> [ShellMark] {
        var scanner = ShellMarkScanner()
        return chunks.flatMap { scanner.scan(Array($0.utf8)) }
    }

    @Test func readsACommandCycle() {
        let output = "\u{1B}]133;A\u{07}$ ls\r\n\u{1B}]133;C\u{07}README.md\r\n\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}$ "
        #expect(scan(output) == [.promptStarted, .commandStarted, .commandFinished(exitCode: 0), .promptStarted])
    }

    @Test func acceptsStringTerminatorAndOptions() {
        #expect(scan("\u{1B}]133;D;127;aid=4\u{1B}\\") == [.commandFinished(exitCode: 127)])
        #expect(scan("\u{1B}]133;D\u{07}") == [.commandFinished(exitCode: nil)])
    }

    @Test func survivesSequencesSplitAcrossReads() {
        #expect(scan("out\u{1B}", "]13", "3;D;", "2", "\u{07}more") == [.commandFinished(exitCode: 2)])
        #expect(scan("\u{1B}]133;C\u{1B}", "\\") == [.commandStarted])
    }

    @Test func ignoresOtherSequences() {
        let output = "\u{1B}]0;title\u{07}\u{1B}[31mred\u{1B}[0m\u{1B}]8;;https://x.dev\u{1B}\\link\u{1B}]8;;\u{1B}\\\u{1B}]1337;D;1\u{07}"
        #expect(scan(output).isEmpty)
    }

    @Test func recoversAfterALongUnrelatedOSC() {
        let clipboard = "\u{1B}]52;c;" + String(repeating: "QUJD", count: 100) + "\u{07}"
        #expect(scan(clipboard + "\u{1B}]133;C\u{07}") == [.commandStarted])
    }

    @Test func marksDriveTheTerminalState() {
        var terminal = Terminal(projectID: UUID(), workingDirectory: URL(filePath: "/tmp"), title: "t")
        terminal.apply(.commandStarted)
        #expect(terminal.state == .running)
        terminal.apply(.commandFinished(exitCode: 1))
        #expect(terminal.state == .idle && terminal.lastExitCode == 1)
        terminal.apply(.commandStarted)
        terminal.apply(.promptStarted)
        #expect(terminal.state == .idle && terminal.lastExitCode == 1)
    }
}
