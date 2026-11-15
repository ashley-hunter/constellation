import ConstellationProcess
import Foundation
import Synchronization

/// A newline-delimited message channel to `codex app-server`. Tests replace it with recorded frames.
protocol CodexTransport: Sendable {
    /// One element per line received, without the newline. Finishes when the peer goes away.
    var lines: AsyncStream<Data> { get }
    func send(_ line: Data) async throws
    /// Closes stdin and terminates the peer. Returns its exit code when known.
    func close() async -> Int32?
}

/// Runs a child process and exchanges newline-delimited messages over its stdin and stdout.
actor CodexProcess: CodexTransport {
    nonisolated let lines: AsyncStream<Data>

    private let process: ChildProcess
    private let stdin: FileHandle

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        let (lines, linesContinuation) = AsyncStream.makeStream(of: Data.self)
        self.lines = lines

        process = try ChildProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: .pipe,
            standardError: .null,
            disclaimsResponsibility: true,
            stopsGroupOnExit: true
        )
        stdin = process.standardInput!

        let buffer = Mutex(Data())
        process.standardOutput?.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                linesContinuation.finish()
                return
            }
            let complete: [Data] = buffer.withLock { pending in
                pending.append(chunk)
                var lines: [Data] = []
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    if !line.isEmpty { lines.append(Data(line)) }
                    pending.removeSubrange(pending.startIndex...newline)
                }
                return lines
            }
            for line in complete { linesContinuation.yield(line) }
        }
    }

    func send(_ line: Data) throws {
        var framed = line
        framed.append(0x0A)
        try stdin.write(contentsOf: framed)
    }

    /// Closing stdin is how app-server learns to quit. If it hasn't after a grace period its process
    /// group gets SIGTERM, then SIGKILL after another.
    func close() async -> Int32? {
        try? stdin.close()
        let process = process
        let timer = Task {
            for signal in [SIGTERM, SIGKILL] {
                try await Task.sleep(for: .seconds(2))
                process.signalGroup(signal)
            }
        }
        defer { timer.cancel() }
        return await process.waitForExit()
    }
}
