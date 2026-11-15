import Foundation

/// What the app saw of a task's run since launch. Nothing yet means it hasn't run this launch,
/// even if the store kept an exit code from last time.
public enum TaskRun: Equatable, Sendable {
    /// Run was pressed and its command hasn't started yet.
    case starting
    /// Its command started and hasn't been seen to end.
    case started
    /// Stop was pressed while its command ran: however the command then ends (npm exits 1 on ⌃C,
    /// say), the run was stopped, not failed.
    case stopping
    /// Its command ended with this code, and the lines that said why if it failed.
    case ended(code: Int32?, at: Date, lines: [String])

    /// The run after a mark from the task's shell. While `awaitingPrompt` (Run is waiting for the
    /// shell's prompt to type its command), a command ending is the one being replaced.
    public static func after(_ mark: ShellMark, from run: TaskRun?, awaitingPrompt: Bool, lines: @autoclosure () -> [String], at now: Date = .now) -> TaskRun? {
        guard !awaitingPrompt else { return run }
        switch mark {
        case .commandStarted: return .started
        case .commandFinished(let code):
            if run == .stopping { return .ended(code: TaskPhase.interruptCode, at: now, lines: []) }
            return .ended(code: code, at: now, lines: lines())
        case .promptStarted: return run
        }
    }
}

/// Where a task is, for its card, title, button and panel. Derived by ``init(_:run:server:)``.
public enum TaskPhase: Equatable, Sendable {
    case notRun
    case starting
    case running(server: URL?)
    case succeeded(at: Date)
    case failed(code: Int32, at: Date, lines: [String])
    /// Stopped with ⌃C (exit 130), or seen to start and never to end.
    case stopped(at: Date?)

    /// Exit 130 is ⌃C: on a task that's stopping it, not failing. A plain shell keeps it as a failure.
    public static let interruptCode: Int32 = 130

    /// The task's phase from its terminal, what this launch saw of its run, and the dev server it printed.
    public init(_ task: Terminal, run: TaskRun?, server: URL?) {
        switch run {
        case .starting?:
            self = .starting
        case _ where task.state == .running:
            self = .running(server: server)
        case nil:
            self = .notRun
        case .started?, .stopping?:
            self = .stopped(at: nil)
        case .ended(let code?, let at, _)? where code == Self.interruptCode:
            self = .stopped(at: at)
        case .ended(let code?, let at, let lines)? where code != 0:
            self = .failed(code: code, at: at, lines: lines.isEmpty ? ["Exited with code \(code)."] : lines)
        case .ended(_, let at, _)?:
            self = .succeeded(at: at)
        }
    }

    /// Starting or running: Stop applies, rather than Run or Restart.
    public var isActive: Bool {
        switch self {
        case .starting, .running: true
        default: false
        }
    }
}
