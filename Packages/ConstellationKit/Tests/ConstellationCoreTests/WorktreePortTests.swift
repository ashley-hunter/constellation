import Foundation
import Testing
@testable import ConstellationCore

@Suite struct WorktreePortTests {
    private let worktree = URL(filePath: "/repos/.constellation/worktrees/shop/quiet-fox")

    @Test func theSamePathGetsTheSamePortInRange() {
        let port = WorktreePort.port(for: worktree) { _ in false }
        #expect(WorktreePort.range.contains(port))
        #expect(WorktreePort.port(for: URL(filePath: "/repos/.constellation/worktrees/shop/quiet-fox/")) { _ in false } == port)
        #expect(WorktreePort.port(for: URL(filePath: "/repos/.constellation/worktrees/shop/bold-owl")) { _ in false } != port)
    }

    @Test func aTakenPortIsSkipped() {
        let port = WorktreePort.port(for: worktree) { _ in false }
        let next = WorktreePort.port(for: worktree) { $0 == port }
        #expect(next != port)
        #expect(WorktreePort.range.contains(next))
    }

    @Test func theEnvironmentNamesItTwice() {
        #expect(WorktreePort.environment(4127) == ["PORT": "4127", "CONSTELLATION_PORT": "4127"])
    }
}
