import Foundation
import Testing
@testable import ConstellationCore

@Test func sessionRoundTripsThroughJSON() throws {
    let session = Session(
        projectID: UUID(),
        provider: .claudeCode,
        model: "opus",
        title: "Fix login",
        worktreePath: URL(filePath: "/tmp/wt"),
        branch: "constellation/abcd1234",
        baseBranch: "main"
    )
    let data = try JSONEncoder().encode(session)
    #expect(try JSONDecoder().decode(Session.self, from: data) == session)
}
