import ConstellationProcess
import Foundation

/// Runs short-lived helper commands (`gh`, `git`) and returns their trimmed stdout.
enum Subprocess {
    struct Failure: Error {
        var status: Int32
        var stderr: String
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil) async throws -> String {
        let process = try ChildProcess(
            executable: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            currentDirectory: directory
        )
        let status = await process.waitForExit()
        // Outputs here are a token or a few remote lines, well under the pipe buffer.
        let out = String(decoding: process.standardOutput!.readDataToEndOfFile(), as: UTF8.self)
        guard status == 0 else {
            let err = String(decoding: process.standardError!.readDataToEndOfFile(), as: UTF8.self)
            throw Failure(status: status, stderr: err)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds a command in the usual install locations, since a GUI app does not inherit the login shell's PATH.
    static func locate(_ name: String) -> URL? {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathEntries
        return candidates
            .map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
