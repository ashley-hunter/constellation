import Foundation
import Testing
@testable import ConstellationProviders

@Suite struct LineBufferTests {
    @Test func splitsAcrossChunksAndDropsBlankLines() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(buffer.append(Data(":2}\r\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(buffer.append(Data("tail".utf8)).isEmpty)
        #expect(buffer.flush() == Data("tail".utf8))
        #expect(buffer.flush() == nil)
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsMixedValues() throws {
        let value: JSONValue = ["s": "x", "i": 3, "d": .double(1.5), "b": true, "n": nil, "a": [1, "two"]]
        #expect(try JSONValue.decode(value.encoded()) == value)
        #expect(String(decoding: try (["p": "/a/b"] as JSONValue).encoded(), as: UTF8.self) == #"{"p":"/a/b"}"#)
    }
}

@Suite struct JSONLineProcessTests {
    @Test func echoesLinesAndExitsWhenInputCloses() async throws {
        let process = try JSONLineProcess(
            executable: URL(filePath: "/bin/cat"),
            arguments: [],
            environment: [:],
            currentDirectory: FileManager.default.temporaryDirectory
        )
        try process.write(Data(#"{"n":1}"#.utf8))
        try process.write(Data(#"{"n":2}"#.utf8))
        process.closeInput()

        var lines: [String] = []
        for await line in process.lines { lines.append(String(decoding: line, as: UTF8.self)) }
        #expect(lines == [#"{"n":1}"#, #"{"n":2}"#])
        #expect(await process.waitForExit() == 0)
        #expect(throws: (any Error).self) { try process.write(Data("late".utf8)) }
    }

    @Test func reportsSignalExitsAndStderr() async throws {
        let process = try JSONLineProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo 'oh no' >&2; sleep 30"],
            environment: [:],
            currentDirectory: FileManager.default.temporaryDirectory
        )
        #expect(await process.waitForExit(timeout: .milliseconds(200)) == nil)
        process.signalGroup(SIGTERM)
        #expect(await process.waitForExit() == 128 + SIGTERM)
        for _ in 0..<50 where process.stderrTail.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(process.stderrTail == ["oh no"])
    }
}

@Suite struct BinaryLocatorTests {
    @Test func findsExecutablesOnTheShellPathAndCaches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appending(path: "fake-claude")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))

        let locator = BinaryLocator(pathProvider: { "/nonexistent:\(directory.path(percentEncoded: false))" })
        #expect(try await locator.locate("fake-claude") == tool)
        #expect(await locator.searchPath().hasPrefix("/nonexistent:\(directory.path(percentEncoded: false)):"))
        await #expect(throws: ProviderError.binaryNotFound("no-such-tool-xyz")) {
            try await locator.locate("no-such-tool-xyz")
        }

        try FileManager.default.removeItem(at: tool)
        #expect(try await locator.locate("fake-claude") == tool, "cached until invalidated")
        await locator.invalidate()
        await #expect(throws: ProviderError.self) { try await locator.locate("fake-claude") }
    }

    @Test func readsTheLoginShellPath() async throws {
        let path = try #require(await BinaryLocator.loginShellPATH())
        #expect(path.contains("/usr/bin"))
    }
}
