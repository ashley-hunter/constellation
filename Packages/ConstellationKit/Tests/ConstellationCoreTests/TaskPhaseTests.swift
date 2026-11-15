import Foundation
import Testing
@testable import ConstellationCore

@Suite struct TaskPhaseTests {
    private let at = Date(timeIntervalSince1970: 1_000)
    private let server = URL(string: "http://localhost:5173/")!

    private func task(_ state: Terminal.State = .idle, lastExitCode: Int32? = nil) -> Terminal {
        Terminal(projectID: projectA, workingDirectory: URL(filePath: "/repo"), title: "dev", state: state, lastExitCode: lastExitCode, command: "npm run dev")
    }

    @Test func oneRestoredFromLastLaunchHasNotRunEvenWithAnExitCode() {
        #expect(TaskPhase(task(lastExitCode: 1), run: nil, server: nil) == .notRun)
        #expect(TaskPhase(task(lastExitCode: 0), run: nil, server: nil) == .notRun)
    }

    @Test func startingWinsOverTheRunItReplaces() {
        #expect(TaskPhase(task(.running), run: .starting, server: server) == .starting)
        #expect(TaskPhase(task(lastExitCode: 1), run: .starting, server: nil) == .starting)
    }

    @Test func runningCarriesItsServer() {
        #expect(TaskPhase(task(.running), run: .started, server: server) == .running(server: server))
        // A command typed into the task's shell by hand runs too.
        #expect(TaskPhase(task(.running), run: nil, server: nil) == .running(server: nil))
    }

    @Test func howItEnded() {
        #expect(TaskPhase(task(), run: .ended(code: 0, at: at, lines: []), server: nil) == .succeeded(at: at))
        #expect(TaskPhase(task(), run: .ended(code: nil, at: at, lines: []), server: nil) == .succeeded(at: at))
        #expect(TaskPhase(task(), run: .ended(code: 2, at: at, lines: ["✗ broke"]), server: nil) == .failed(code: 2, at: at, lines: ["✗ broke"]))
        #expect(TaskPhase(task(), run: .ended(code: 1, at: at, lines: []), server: nil) == .failed(code: 1, at: at, lines: ["Exited with code 1."]))
    }

    @Test func controlCStopsATaskRatherThanFailingIt() {
        #expect(TaskPhase(task(), run: .ended(code: 130, at: at, lines: ["^C"]), server: nil) == .stopped(at: at))
    }

    @Test func startedAndBackAtAPromptWithoutAnEndIsStopped() {
        #expect(TaskPhase(task(), run: .started, server: nil) == .stopped(at: nil))
    }

    @Test func onlyStartingAndRunningCanBeStopped() {
        #expect(TaskPhase.starting.isActive && TaskPhase.running(server: nil).isActive)
        #expect(![TaskPhase.notRun, .succeeded(at: at), .stopped(at: nil), .failed(code: 1, at: at, lines: [])].contains { $0.isActive })
    }

    @Test func aRunFollowsItsShellsMarks() {
        var run: TaskRun? = .starting
        run = TaskRun.after(.promptStarted, from: run, awaitingPrompt: false, lines: [], at: at)
        #expect(run == .starting)
        run = TaskRun.after(.commandStarted, from: run, awaitingPrompt: false, lines: [], at: at)
        #expect(run == .started)
        run = TaskRun.after(.commandFinished(exitCode: 1), from: run, awaitingPrompt: false, lines: ["✗ broke"], at: at)
        #expect(run == .ended(code: 1, at: at, lines: ["✗ broke"]))
    }

    @Test func restartingIgnoresTheEndOfTheRunItReplaces() {
        // Restart sent ⌃C and waits for the prompt: the old command's 130 isn't this run's result.
        let run = TaskRun.after(.commandFinished(exitCode: 130), from: .starting, awaitingPrompt: true, lines: [], at: at)
        #expect(run == .starting)
        #expect(TaskPhase(task(), run: run, server: nil) == .starting)
    }

    @Test func outputIsReadOnlyAsTheCommandEnds() {
        var reads = 0
        func lines() -> [String] { reads += 1; return [] }
        _ = TaskRun.after(.commandStarted, from: nil, awaitingPrompt: false, lines: lines(), at: at)
        _ = TaskRun.after(.promptStarted, from: nil, awaitingPrompt: false, lines: lines(), at: at)
        #expect(reads == 0)
        _ = TaskRun.after(.commandFinished(exitCode: 0), from: .started, awaitingPrompt: false, lines: lines(), at: at)
        #expect(reads == 1)
    }
}

@Suite struct TerminalKindTests {
    private func terminal(url: URL? = nil, command: String? = nil, note: String? = nil) -> Terminal {
        Terminal(projectID: projectA, workingDirectory: URL(filePath: "/repo"), title: "t", url: url, command: command, note: note)
    }

    @Test func eachKindFromTheOneFieldSet() {
        #expect(terminal().kind == .shell)
        #expect(terminal(command: "make").kind == .task)
        #expect(terminal(url: URL(string: "https://example.com")).kind == .browser)
        #expect(terminal(note: "").kind == .note)
    }

    @Test func aBrowserWinsThenANoteThenATask() {
        let url = URL(string: "https://example.com")
        #expect(terminal(url: url, command: "make", note: "x").kind == .browser)
        #expect(terminal(command: "make", note: "x").kind == .note)
        #expect(terminal(url: url, command: "make").kind == .browser)
    }

    @Test func aRunStoppedByHandReadsStoppedWhateverItsExitCode() {
        // npm exits 1, not 130, when ⌃C stops the server under it.
        let ended = TaskRun.after(.commandFinished(exitCode: 1), from: .stopping, awaitingPrompt: false, lines: ["npm ERR!"])
        guard case .ended(let code?, _, let lines)? = ended else { Issue.record("not ended"); return }
        #expect(code == TaskPhase.interruptCode)
        #expect(lines.isEmpty)
    }
}
