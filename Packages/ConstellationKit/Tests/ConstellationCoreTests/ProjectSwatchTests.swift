import Foundation
import Testing
@testable import ConstellationCore

struct ProjectSwatchTests {
    private func project(_ swatch: ProjectSwatch) -> Project {
        Project(name: "p", rootPath: URL(filePath: "/tmp/p"), swatch: swatch)
    }

    @Test func nextPicksTheFirstUnusedSwatch() {
        #expect(ProjectSwatch.next(after: []) == .sage)
        #expect(ProjectSwatch.next(after: [.sage, .rose]) == .lavender)
    }

    @Test func repeatedSwatchesMoveToUnusedOnesAndTheFirstKeepsItsOwn() {
        let projects = [.slate, .slate, .sage, .slate].map(project)
        let swatches = ProjectSwatch.unique(projects).map(\.swatch)
        #expect(swatches.first == .slate)
        #expect(Set(swatches).count == 4)
        #expect(ProjectSwatch.unique(projects).map(\.id) == projects.map(\.id))
    }

    @Test func beyondTenProjectsColoursRepeatRatherThanFail() {
        let projects = Array(repeating: ProjectSwatch.sage, count: 12).map(project)
        let swatches = ProjectSwatch.unique(projects).map(\.swatch)
        #expect(Set(swatches.prefix(10)).count == 10)
        #expect(swatches.count == 12)
    }
}

struct DigitLabelTests {
    @Test func tenOrFewerUseSingleDigits() {
        #expect(JumpHints.digitLabels(count: 3) == ["1", "2", "3"])
        #expect(JumpHints.digitLabels(count: 10).last == "0")
    }

    @Test func moreThanTenKeepOneToNineAndPrefixTheRestWithZero() {
        let twelve = JumpHints.digitLabels(count: 12)
        #expect(twelve == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "01", "02", "03"])
        let many = JumpHints.digitLabels(count: 34)
        #expect(many.prefix(9) == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(many.last == "025")
        #expect(Set(many).count == 34)
        // No label starts another, so a jump never waits for more digits.
        #expect(!many.contains { a in many.contains { b in a != b && b.hasPrefix(a) } })
    }
}
