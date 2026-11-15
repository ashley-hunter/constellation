import Darwin
import Foundation
import Testing
@testable import ConstellationProcess

/// The built `constellation-mcp` stands in for a provider and runs the watchdog. They need `swift build` to have built the helper.
@Suite(.serialized) struct HelperModeTests {
    static var helper: URL? {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        return [
            bundle?.bundleURL.deletingLastPathComponent().appending(path: "constellation-mcp"),
            URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug/constellation-mcp"),
        ].compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    @Test(.enabled(if: helper != nil)) func watchdogStopsLeftoversWhenItsPipeCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watchdog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let child = try ChildProcess(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:], tracked: false)
        ChildRegistry.writeFile(for: child.pid, name: "sleep", in: directory)

        let watchdog = try ChildRegistry.startWatchdog(helper: #require(Self.helper), arguments: ["--watchdog", directory.path(percentEncoded: false)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(child.isRunning, "the watchdog waits while the pipe is open")

        try watchdog.standardInput?.close()
        #expect(await child.waitForExit() == 128 + SIGTERM)
        #expect(await watchdog.waitForExit() == 0)
    }

    @Test(.enabled(if: helper != nil)) func aDisclaimedProviderIsResponsibleForItself() async throws {
        let helper = try #require(Self.helper)
        #expect(!Responsibility.isPlatformBinary(helper))
        let child = try ChildProcess(
            executable: helper, arguments: [], environment: [:], standardInput: .pipe, disclaimsResponsibility: true
        )
        defer { child.signal(SIGKILL) }
        #expect(ChildProcess.responsibleProcess(for: child.pid) == child.pid)
    }
}
