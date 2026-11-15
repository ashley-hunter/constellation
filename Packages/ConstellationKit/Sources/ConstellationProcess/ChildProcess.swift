import Darwin
import Foundation
import os

/// A child process spawned the way every Constellation child should be: leading its own process
/// group, with default signal handling, no inherited file descriptors beyond its stdio, and a pid
/// file while it runs (see ``ChildRegistry``). Providers also disclaim responsibility (see
/// ``Responsibility``). A child given a `terminal` leads its own session instead, with that
/// terminal as its controlling terminal and its stdio (see ``PseudoTerminal``).
public final class ChildProcess: Sendable {
    public enum Input: Sendable {
        case pipe, null
    }

    public enum Output: Sendable {
        case pipe, null
        /// Stderr only: write to the same place as stdout.
        case standardOutput
    }

    public let pid: pid_t
    /// The write end of stdin, when it is a pipe.
    public let standardInput: FileHandle?
    /// The read end of stdout, when it is a pipe.
    public let standardOutput: FileHandle?
    /// The read end of stderr, when it is a separate pipe.
    public let standardError: FileHandle?

    private let tracked: Bool
    private let stopsGroupOnExit: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var exitCode: Int32?
        var waiters: [@Sendable (Int32) -> Void] = []
    }

    public init(
        executable: URL,
        arguments: [String],
        argv0: String? = nil,
        environment: [String: String],
        currentDirectory: URL? = nil,
        standardInput stdinMode: Input = .null,
        standardOutput stdoutMode: Output = .pipe,
        standardError stderrMode: Output = .pipe,
        terminal: String? = nil,
        disclaimsResponsibility: Bool = false,
        tracked: Bool = true,
        stopsGroupOnExit: Bool = false
    ) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var parentEnds: [Int32] = []
        var childEnds: [Int32] = []
        defer { childEnds.forEach { close($0) } }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        // Parent ends stay raw descriptors until the spawn succeeds, so a failure closes each once.
        do {
            var stdinWrite: Int32?
            var stdoutRead: Int32?
            var stderrRead: Int32?
            if let terminal {
                // Opened in the child after it leads its new session, so it becomes the controlling terminal.
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, terminal, O_RDWR, 0)
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
                posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
            } else {
                switch stdinMode {
                case .pipe:
                    let (read, write) = try makePipe()
                    childEnds.append(read)
                    parentEnds.append(write)
                    posix_spawn_file_actions_adddup2(&actions, read, STDIN_FILENO)
                    stdinWrite = write
                case .null:
                    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                }

                func output(_ mode: Output, to target: Int32) throws -> Int32? {
                    switch mode {
                    case .pipe:
                        let (read, write) = try makePipe()
                        childEnds.append(write)
                        parentEnds.append(read)
                        posix_spawn_file_actions_adddup2(&actions, write, target)
                        return read
                    case .null:
                        posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
                        return nil
                    case .standardOutput:
                        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, target)
                        return nil
                    }
                }
                stdoutRead = try output(stdoutMode == .standardOutput ? .pipe : stdoutMode, to: STDOUT_FILENO)
                stderrRead = try output(stderrMode, to: STDERR_FILENO)
            }

            if let currentDirectory {
                posix_spawn_file_actions_addchdir(&actions, currentDirectory.path(percentEncoded: false))
            }

            // A session leader leads its own process group too.
            var attributes = Self.attributes(flags: terminal == nil ? POSIX_SPAWN_SETPGROUP : POSIX_SPAWN_SETSID)
            posix_spawnattr_setpgroup(&attributes, 0)
            if disclaimsResponsibility { Responsibility.disclaim(&attributes, executable: executable) }
            defer { posix_spawnattr_destroy(&attributes) }

            var path = executable.path(percentEncoded: false)
            var argv = [argv0 ?? path] + arguments
            if terminal != nil {
                // posix_spawn opens the terminal before the child leads its session, so on macOS it
                // doesn't become the controlling terminal and ⌃C never reaches the foreground job.
                // sh takes it as it starts, then becomes the real program, argv0 and all.
                argv = ["sh", "-c", #"exec -a "$0" "$@""#, argv[0], path] + arguments
                path = "/bin/sh"
            }
            let envp = environment.map { "\($0.key)=\($0.value)" }
            var spawned: pid_t = 0
            let status = Self.withCStrings(argv) { argv in
                Self.withCStrings(envp) { envp in
                    posix_spawn(&spawned, path, &actions, &attributes, argv, envp)
                }
            }
            guard status == 0 else {
                throw POSIXError(.init(rawValue: status) ?? .EIO)
            }
            pid = spawned
            let handle = { (fd: Int32?) in fd.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) } }
            standardInput = handle(stdinWrite)
            standardOutput = handle(stdoutRead)
            standardError = handle(stderrRead)
        } catch {
            parentEnds.forEach { close($0) }
            throw error
        }

        self.tracked = tracked
        self.stopsGroupOnExit = stopsGroupOnExit
        if tracked { ChildRegistry.register(pid, name: executable.lastPathComponent) }
        monitorExit()
    }

    /// The exit status, or 128 plus the signal number when a signal ended the process. Nil while running.
    public var exitCode: Int32? {
        state.withLock { $0.exitCode }
    }

    public var isRunning: Bool { exitCode == nil }

    /// Calls `body` once the process has exited, straight away if it already has.
    public func onExit(_ body: @escaping @Sendable (Int32) -> Void) {
        let code = state.withLock { state -> Int32? in
            if let code = state.exitCode { return code }
            state.waiters.append(body)
            return nil
        }
        if let code { body(code) }
    }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            onExit { continuation.resume(returning: $0) }
        }
    }

    /// Signals the process, unless it has been reaped (its pid could have been reused).
    public func signal(_ signal: Int32) {
        state.withLock { state in
            if state.exitCode == nil { kill(pid, signal) }
        }
    }

    /// Signals the whole process group, so grandchildren holding pipes open go too.
    public func signalGroup(_ signal: Int32) {
        state.withLock { state in
            if state.exitCode == nil { kill(-pid, signal) }
        }
    }

    /// Kills whatever is left in the process group after its leader has gone, such as a child the
    /// leader forked just as it was told to stop. A group's id can't be reused while any member is
    /// alive, so this only reaches our own leftovers.
    public func killLeftoverGroup() {
        kill(-pid, SIGKILL)
    }

    /// A thread blocked in waitpid, rather than a kqueue source, which never fires for a child
    /// that exits before the source is registered.
    private func monitorExit() {
        let pid = pid
        let thread = Thread { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            finish(result == pid ? Self.exitCode(fromWaitStatus: status) : 255)
        }
        thread.name = "ChildProcess \(pid)"
        thread.stackSize = 64 * 1024
        thread.start()
    }

    private func finish(_ code: Int32) {
        let waiters = state.withLock { state in
            state.exitCode = code
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        // Whatever the child started, like an MCP server or a background shell, would otherwise
        // outlive it with no pid file. While the group has members its id can't be reused.
        if stopsGroupOnExit { kill(-pid, SIGTERM) }
        if tracked { ChildRegistry.unregister(pid) }
        for waiter in waiters { waiter(code) }
    }

    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    /// Default signal dispositions (the app ignores SIGPIPE), an empty signal mask, and only the
    /// stdio descriptors inherited.
    private static func attributes(flags: Int32) -> posix_spawnattr_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(flags | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        return attributes
    }

    /// The process macOS holds responsible for `pid`, for checking that a child disclaimed.
    public static func responsibleProcess(for pid: pid_t) -> pid_t? {
        Responsibility.responsibleProcess(for: pid)
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
