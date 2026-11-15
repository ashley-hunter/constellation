import Foundation
import Testing
@testable import ConstellationCore

@Suite struct ProjectTaskTests {
    @Test func offersScriptsThroughTheLockfilesManagerAndMakeTargets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"scripts": {"test": "vitest", "dev": "vite"}}"#.utf8).write(to: root.appending(path: "package.json"))
        try Data().write(to: root.appending(path: "pnpm-lock.yaml"))
        try Data(".PHONY: build\nCC := clang\nbuild: deps\n\tswift build\n%.o: %.c\nbuild:\nlint:\n".utf8).write(to: root.appending(path: "Makefile"))

        #expect(ProjectTask.suggestions(in: root).map(\.command) == ["pnpm dev", "pnpm test", "make build", "make lint"])
    }

    @Test func npmRunsWithoutALockfile() {
        #expect(ProjectTask.packageManager(in: URL(filePath: "/nonexistent")) == "npm")
    }
}
