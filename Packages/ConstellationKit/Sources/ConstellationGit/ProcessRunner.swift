import ConstellationProcess
import Foundation

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a child process to completion without blocking the cooperative pool.
/// Cancelling the calling task, or passing the timeout, terminates the child's process group,
/// so grandchildren holding the pipes open (a setup script's `npm install`) go too.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        mergeOutput: Bool = false,
        timeout: Duration? = nil,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = try ChildProcess(
            executable: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment.merging(environment) { $1 },
            currentDirectory: directory,
            standardError: mergeOutput ? .standardOutput : .pipe
        )

        let timer = timeout.map { limit in
            Task {
                try await Task.sleep(for: limit)
                terminateGroup(of: process)
            }
        }
        defer { timer?.cancel() }

        return await withTaskCancellationHandler {
            async let stdout = drain(process.standardOutput, onOutput: onOutput)
            async let stderr = drain(process.standardError, onOutput: nil)
            let status = await process.waitForExit()
            // Cancelled: anything the leader forked while being stopped would hold the pipes open.
            if Task.isCancelled { process.killLeftoverGroup() }
            return await ProcessOutput(status: status, stdout: stdout, stderr: stderr)
        } onCancel: {
            terminateGroup(of: process)
        }
    }

    /// Each child leads its own process group. SIGTERM lets git release its locks; SIGKILL follows
    /// for anything that ignored it.
    private static func terminateGroup(of process: ChildProcess) {
        process.signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { process.signalGroup(SIGKILL) }
    }

    private static func drain(_ handle: FileHandle?, onOutput: (@Sendable (Data) -> Void)?) async -> Data {
        guard let handle else { return Data() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var collected = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    collected.append(chunk)
                    onOutput?(chunk)
                }
                continuation.resume(returning: collected)
            }
        }
    }
}
