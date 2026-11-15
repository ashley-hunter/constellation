import Darwin
import Foundation
import Synchronization
import Testing
@testable import ConstellationProcess

@Suite(.serialized) struct PseudoTerminalTests {
    /// Collects a terminal's output until the program exits and the pty closes.
    final class Output: Sendable {
        private let bytes = Mutex(Data())
        private let closed = Mutex(false)

        func append(_ data: Data) { bytes.withLock { $0.append(data) } }
        var text: String { String(decoding: bytes.withLock { $0 }, as: UTF8.self) }

        func waitFor(_ needle: String, timeout: Duration = .seconds(5)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if text.contains(needle) { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return text.contains(needle)
        }
    }

    @Test func runsWithThePtyAsItsControllingTerminalAtItsSize() async throws {
        let terminal = try PseudoTerminal(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "stty size; exec 3</dev/tty && echo has-tty; ps -o tpgid= -p $$; echo \"$GREETING\" $(pwd -P)"],
            argv0: "sh",
            environment: ["GREETING": "hi"],
            currentDirectory: URL(filePath: "/usr/bin"),
            columns: 77,
            rows: 33
        )
        let output = Output()
        terminal.startReading { output.append($0) }
        #expect(await terminal.process.waitForExit() == 0)
        #expect(await output.waitFor("/usr/bin"))
        let text = output.text
        #expect(text.contains("33 77"))
        #expect(text.contains("has-tty"))
        // The shell leads the terminal's foreground process group.
        #expect(text.contains("\(terminal.process.pid)"))
        #expect(text.contains("hi /usr/bin"))
    }

    /// zsh, unlike sh, doesn't take the terminal for itself, so it gets one, and ⌃C reaches its
    /// jobs, only through the spawn.
    @Test func zshGetsTheTerminal() async throws {
        let terminal = try PseudoTerminal(
            executable: URL(filePath: "/bin/zsh"),
            arguments: ["-f", "-c", "exec 3</dev/tty && echo has-tty"],
            argv0: "-zsh",
            environment: [:]
        )
        let output = Output()
        terminal.startReading { output.append($0) }
        #expect(await terminal.process.waitForExit() == 0)
        #expect(await output.waitFor("has-tty"))
    }

    @Test func passesInputResizesAndHangsUp() async throws {
        let terminal = try PseudoTerminal(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "trap 'stty size' WINCH; read line; echo \"got $line\"; while :; do sleep 0.05; done"],
            environment: [:]
        )
        let output = Output()
        terminal.startReading { output.append($0) }
        #expect(getsid(terminal.process.pid) == terminal.process.pid)
        terminal.write(Data("hello\r".utf8))
        #expect(await output.waitFor("got hello"))
        terminal.resize(columns: 100, rows: 40)
        #expect(await output.waitFor("40 100"))
        terminal.hangUp()
        #expect(await terminal.process.waitForExit() == 128 + SIGHUP)
    }
}
