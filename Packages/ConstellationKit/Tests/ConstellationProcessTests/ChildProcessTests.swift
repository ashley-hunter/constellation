import Darwin
import Foundation
import Testing
@testable import ConstellationProcess

@Suite(.serialized) struct ChildProcessTests {
    @Test func runsInItsFolderWithItsEnvironmentAndReportsTheExitCode() async throws {
        let folder = URL(filePath: "/usr/bin")
        let child = try ChildProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo \"$GREETING $(pwd -P)\"; echo oops >&2; exit 3"],
            environment: ["GREETING": "hi"],
            currentDirectory: folder
        )
        let output = String(decoding: try #require(child.standardOutput).readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: try #require(child.standardError).readDataToEndOfFile(), as: UTF8.self)
        #expect(await child.waitForExit() == 3)
        #expect(output == "hi /usr/bin\n")
        #expect(errors == "oops\n")
    }

    @Test func platformBinariesStayAttributedToTheApp() async throws {
        let child = try ChildProcess(
            executable: URL(filePath: "/bin/sleep"), arguments: ["5"], environment: [:], disclaimsResponsibility: true
        )
        defer { child.signal(SIGKILL) }
        #expect(Responsibility.isPlatformBinary(URL(filePath: "/bin/sleep")))
        #expect(ChildProcess.responsibleProcess(for: child.pid) == ChildProcess.responsibleProcess(for: getpid()))
    }

    @Test func leadsItsOwnProcessGroupWithDefaultSignals() async throws {
        signal(SIGPIPE, SIG_IGN)
        // `trap` lists only dispositions that differ from the default.
        let child = try ChildProcess(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "trap; sleep 5"], environment: [:])
        #expect(getpgid(child.pid) == child.pid)
        child.signalGroup(SIGTERM)
        #expect(await child.waitForExit() == 128 + SIGTERM)
        let traps = String(decoding: try #require(child.standardOutput).readDataToEndOfFile(), as: UTF8.self)
        #expect(!traps.contains("PIPE"))
    }

    @Test func passesStdinAndMergesStderr() async throws {
        let child = try ChildProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "cat; echo err >&2"],
            environment: [:],
            standardInput: .pipe,
            standardError: .standardOutput
        )
        let input = try #require(child.standardInput)
        try input.write(contentsOf: Data("in\n".utf8))
        try input.close()
        let output = String(decoding: try #require(child.standardOutput).readDataToEndOfFile(), as: UTF8.self)
        #expect(await child.waitForExit() == 0)
        #expect(output == "in\nerr\n")
    }

    @Test func throwsForAMissingExecutable() {
        #expect(throws: POSIXError.self) {
            try ChildProcess(executable: URL(filePath: "/no/such/tool"), arguments: [], environment: [:])
        }
    }

    /// A provider's background shells and helpers go when it exits, even with no signal sent to it.
    @Test func stopsWhatItStartedWhenItExits() async throws {
        let child = try ChildProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $!"],
            environment: [:],
            tracked: false,
            stopsGroupOnExit: true
        )
        let grandchild = try #require(pid_t(String(decoding: child.standardOutput!.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await child.waitForExit() == 0)
        for _ in 0..<50 where kill(grandchild, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(grandchild, 0) == -1)
    }

    @Test func decodesWaitStatuses() {
        #expect(ChildProcess.exitCode(fromWaitStatus: 0) == 0)
        #expect(ChildProcess.exitCode(fromWaitStatus: 254 << 8) == 254)
        #expect(ChildProcess.exitCode(fromWaitStatus: SIGKILL) == 128 + SIGKILL)
    }
}

@Suite(.serialized) struct ChildRegistryTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "children-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func writesAPidFileWhileTheChildRuns() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        ChildRegistry.track(in: directory)
        defer { ChildRegistry.stopTracking() }

        let child = try ChildProcess(executable: URL(filePath: "/bin/sleep"), arguments: ["5"], environment: [:])
        let file = directory.appending(path: "\(child.pid).pid")
        let leftover = try #require(ChildRegistry.parse(String(contentsOf: file, encoding: .utf8)))
        #expect(leftover.pid == child.pid)
        #expect(leftover.name == "sleep")
        #expect(ChildRegistry.isAlive(leftover))

        child.signal(SIGTERM)
        _ = await child.waitForExit()
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func sweepStopsLeftoversAndTheirChildren() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A shell that ignores SIGTERM and has a child of its own, like a provider running a command.
        let child = try ChildProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & echo $!; wait"],
            environment: [:],
            tracked: false
        )
        ChildRegistry.writeFile(for: child.pid, name: "sh", in: directory)
        let grandchild = try #require(pid_t(String(decoding: child.standardOutput!.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        let leftovers = ChildRegistry.collectLeftovers(in: directory)
        #expect(leftovers.map(\.pid) == [child.pid])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)

        await ChildRegistry.stop(leftovers, grace: .milliseconds(300))
        #expect(await child.waitForExit() == 128 + SIGKILL)
        for _ in 0..<50 where kill(grandchild, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(grandchild, 0) == -1)
    }

    @Test func ignoresPidFilesForProcessesThatHaveGoneOrBeenReplaced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = try #require(ChildRegistry.startTime(of: getpid()))
        try "\(getpid()) \(mine + 1)\nimpostor\n".write(to: directory.appending(path: "\(getpid()).pid"), atomically: true, encoding: .utf8)
        try "99999 1\ngone\n".write(to: directory.appending(path: "99999.pid"), atomically: true, encoding: .utf8)
        try "junk".write(to: directory.appending(path: "1.pid"), atomically: true, encoding: .utf8)
        #expect(ChildRegistry.collectLeftovers(in: directory).isEmpty)
    }

    /// Only runs whose app has gone are swept, so a second copy of the app leaves the first alone.
    @Test func sweepSkipsTheFoldersOfRunsStillGoing() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let live = ChildRegistry.runDirectory(in: base)
        let ended = base.appending(path: "99999-1", directoryHint: .isDirectory)
        for folder in [live, ended] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let mine = try ChildProcess(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:], tracked: false)
        let theirs = try ChildProcess(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:], tracked: false)
        defer { mine.signal(SIGKILL); theirs.signal(SIGKILL) }
        ChildRegistry.writeFile(for: mine.pid, name: "mine", in: live)
        ChildRegistry.writeFile(for: theirs.pid, name: "theirs", in: ended)

        let leftovers = ChildRegistry.collectLeftovers(ofEndedRunsIn: base)
        #expect(leftovers.map(\.pid) == [theirs.pid])
        #expect(FileManager.default.fileExists(atPath: live.appending(path: "\(mine.pid).pid").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: ended.path(percentEncoded: false)))
    }
}
