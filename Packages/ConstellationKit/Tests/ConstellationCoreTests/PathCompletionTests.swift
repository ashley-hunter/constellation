import ConstellationCore
import Foundation
import Testing

@Suite struct PathCompletionTests {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    @Test func splitsAtTheLastSlash() {
        #expect(PathCompletion.split("~/code/con") == ("~/code/", "con"))
        #expect(PathCompletion.split("~/code/") == ("~/code/", ""))
        #expect(PathCompletion.split("name") == ("", "name"))
    }

    @Test func resolvesHomeAbsoluteAndRelative() {
        let base = URL(filePath: "/Users/someone/code", directoryHint: .isDirectory)
        #expect(PathCompletion.resolve("~/src/", base: base, home: home).path(percentEncoded: false) == "/Users/someone/src/")
        #expect(PathCompletion.resolve("/tmp/x", base: base, home: home).path(percentEncoded: false) == "/tmp/x/")
        #expect(PathCompletion.resolve("work/", base: base, home: home).path(percentEncoded: false) == "/Users/someone/code/work/")
        #expect(PathCompletion.resolve("", base: base, home: home) == base.standardizedFileURL)
    }

    @Test func matchesByPrefixAndHidesDotFoldersUntilAsked() {
        let names = ["Constellation", "code", ".config", "notes"]
        #expect(PathCompletion.matches(names, leaf: "c") == ["Constellation", "code"])
        #expect(PathCompletion.matches(names, leaf: "") == ["Constellation", "code", "notes"])
        #expect(PathCompletion.matches(names, leaf: ".") == [".config"])
    }

    @Test func tabCompletesOneMatchOrTheCommonPrefix() {
        #expect(PathCompletion.completion(["constellation"], leaf: "con")! == ("constellation", true))
        #expect(PathCompletion.completion(["constellation", "Constants"], leaf: "c")! == ("const", false))
        #expect(PathCompletion.completion(["code", "constellation"], leaf: "co") == nil)
        #expect(PathCompletion.completion([], leaf: "x") == nil)
    }
}
