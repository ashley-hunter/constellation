import Darwin
import Foundation
import os

/// A shell (or any program) running on a pseudo-terminal we own: spawned as a ``ChildProcess``
/// leading its own session, with the pty as its controlling terminal. Output arrives on a reader
/// thread; input and window size changes go straight to the pty.
public final class PseudoTerminal: Sendable {
    public let process: ChildProcess
    /// The replica's path, like `/dev/ttys004`.
    public let terminalPath: String

    private let primary: Int32
    /// A copy of the primary for writing, used only on `writes`, so input never blocks the caller
    /// (the main thread) when the program isn't reading, and the reader can close its copy freely.
    private let writer: Int32
    private let writes = DispatchQueue(label: "PseudoTerminal.writes")
    /// Guards the descriptor, so nothing writes to it after the reader closes it and its number is reused.
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var reading = false
        var closed = false
    }

    public init(
        executable: URL,
        arguments: [String] = [],
        argv0: String? = nil,
        environment: [String: String],
        currentDirectory: URL? = nil,
        columns: Int = 80,
        rows: Int = 24
    ) throws {
        var primary: Int32 = -1
        var replica: Int32 = -1
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, nil, &size) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(primary, F_SETFD, FD_CLOEXEC)
        // The replica stays open here until the child has opened its own copy: closing the last
        // one resets the terminal, window size included.
        defer { close(replica) }
        do {
            terminalPath = String(cString: ptsname(primary))
            process = try ChildProcess(
                executable: executable,
                arguments: arguments,
                argv0: argv0,
                environment: environment,
                currentDirectory: currentDirectory,
                terminal: terminalPath
            )
        } catch {
            close(primary)
            throw error
        }
        self.primary = primary
        writer = dup(primary)
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        let writer = writer
        writes.async { close(writer) }
    }

    /// Starts delivering output, on a thread of its own, until every holder of the replica has
    /// closed it. The pty closes after the last delivery. Call once.
    public func startReading(_ deliver: @escaping @Sendable (Data) -> Void) {
        let started = state.withLock { state in
            defer { state.reading = true }
            return state.reading
        }
        guard !started else { return }
        let fd = primary
        let thread = Thread { [state] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    deliver(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    break
                }
            }
            state.withLock { state in
                state.closed = true
                close(fd)
            }
        }
        thread.name = "PseudoTerminal \(process.pid)"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Writes input for the program, as if typed.
    public func write(_ data: Data) {
        guard !state.withLock({ $0.closed }) else { return }
        let writer = writer
        writes.async { Self.write(data, to: writer) }
    }

    private static func write(_ data: Data, to primary: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(primary, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    return
                }
            }
        }
    }

    /// Sets the window size; the program gets SIGWINCH.
    public func resize(columns: Int, rows: Int, widthPixels: Int = 0, heightPixels: Int = 0) {
        guard columns > 0, rows > 0 else { return }
        let size = winsize(
            ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns),
            ws_xpixel: UInt16(clamping: widthPixels), ws_ypixel: UInt16(clamping: heightPixels)
        )
        state.withLock { state in
            guard !state.closed else { return }
            var size = size
            _ = ioctl(primary, TIOCSWINSZ, &size)
        }
    }

    /// Hangs up, as closing a terminal window does: the shell gets SIGHUP and passes it to its jobs.
    public func hangUp() {
        process.signalGroup(SIGHUP)
    }
}
