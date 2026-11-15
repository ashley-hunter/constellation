import ConstellationProcess
import Foundation
import os

/// A provider process that speaks newline-delimited JSON on stdin and stdout. It is responsible
/// for its own file access (see `ChildProcess`).
///
/// Stdout is drained continuously into `lines`, which finishes at EOF. Stderr is kept as a
/// short tail for error messages.
final class JSONLineProcess: Sendable {
    let lines: AsyncStream<Data>
    var processIdentifier: Int32 { process.pid }

    private let process: ChildProcess
    private let stdin: FileHandle
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var inputClosed = false
        var stderrTail: [String] = []
        var stderrBuffer = LineBuffer()
    }

    private static let stderrTailLimit = 20

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL
    ) throws {
        Self.ignoreSIGPIPE

        let process = try ChildProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: .pipe,
            disclaimsResponsibility: true,
            stopsGroupOnExit: true
        )
        self.process = process
        self.stdin = process.standardInput!

        let (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.lines = lines

        let stdoutBuffer = OSAllocatedUnfairLock(initialState: LineBuffer())
        process.standardOutput?.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let rest = stdoutBuffer.withLock({ $0.flush() }) { continuation.yield(rest) }
                continuation.finish()
                return
            }
            for line in stdoutBuffer.withLock({ $0.append(chunk) }) { continuation.yield(line) }
        }

        process.standardError?.readabilityHandler = { [state] handle in
            let chunk = handle.availableData
            state.withLock { state in
                let lines = chunk.isEmpty
                    ? [state.stderrBuffer.flush()].compactMap { $0 }
                    : state.stderrBuffer.append(chunk)
                state.stderrTail.append(contentsOf: lines.map { String(decoding: $0, as: UTF8.self) })
                state.stderrTail = Array(state.stderrTail.suffix(Self.stderrTailLimit))
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
    }

    /// Writes one JSON line. Throws once input is closed or the process has gone away.
    func write(_ line: Data) throws {
        try state.withLock { state in
            guard !state.inputClosed else { throw CocoaError(.fileWriteUnknown) }
            try stdin.write(contentsOf: line + [0x0A])
        }
    }

    func closeInput() {
        let shouldClose = state.withLock { state in
            defer { state.inputClosed = true }
            return !state.inputClosed
        }
        if shouldClose { try? stdin.close() }
    }

    /// Signals the process and everything it started, unless it has already exited.
    func signalGroup(_ signal: Int32) {
        process.signalGroup(signal)
    }

    /// The exit status, or 128 plus the signal number when a signal ended the process.
    func waitForExit() async -> Int32 {
        await process.waitForExit()
    }

    /// Waits up to `timeout` for the process to exit and returns its code, or nil if it is still running.
    func waitForExit(timeout: Duration) async -> Int32? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Int32?) -> Void = { code in
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if first { continuation.resume(returning: code) }
            }
            process.onExit(finish)
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    var stderrTail: [String] {
        state.withLock { $0.stderrTail }
    }

    /// Writing to a pipe whose reader has exited must fail with EPIPE rather than kill the app.
    private static let ignoreSIGPIPE: Void = {
        Darwin.signal(SIGPIPE, SIG_IGN)
    }()
}

/// Splits a byte stream into newline-terminated lines, dropping empty lines and a trailing `\r`.
struct LineBuffer: Sendable {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = trimmed(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }

    mutating func flush() -> Data? {
        defer { pending.removeAll() }
        let line = trimmed(pending[...])
        return line.isEmpty ? nil : Data(line)
    }

    private func trimmed(_ line: Data.SubSequence) -> Data.SubSequence {
        line.last == 0x0D ? line.dropLast() : line
    }
}
