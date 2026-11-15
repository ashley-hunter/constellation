import Foundation
import Testing
@testable import ConstellationMCP

struct SecretStoreTests {
    let store = SecretStore(service: "Constellation.tests.\(UUID().uuidString)")
    let sessionID = UUID()
    let projectID = UUID()

    @Test func savesOverwritesAndDeletesBySession() throws {
        defer { try? store.deleteAll(scope: .session(sessionID)) }
        try store.save("one", name: "TOKEN", scope: .session(sessionID))
        try store.save("two", name: "TOKEN", scope: .session(sessionID))
        #expect(try store.value(name: "TOKEN", scope: .session(sessionID)) == "two")
        #expect(try store.value(name: "TOKEN", scope: .project(projectID)) == nil)

        try store.deleteAll(scope: .session(sessionID))
        #expect(try store.value(name: "TOKEN", scope: .session(sessionID)) == nil)
    }

    @Test func environmentOverlaysSessionOnProject() throws {
        let otherSessionID = UUID()
        defer {
            try? store.deleteAll(scope: .session(otherSessionID))
            try? store.deleteAll(scope: .session(sessionID))
            try? store.deleteAll(scope: .project(projectID))
        }
        try store.save("project", name: "SHARED", scope: .project(projectID))
        try store.save("project-only", name: "API_KEY", scope: .project(projectID))
        try store.save("session", name: "SHARED", scope: .session(sessionID))
        try store.save("elsewhere", name: "OTHER", scope: .session(otherSessionID))

        #expect(try store.environment(sessionID: sessionID, projectID: projectID) == [
            "SHARED": "session",
            "API_KEY": "project-only",
        ])
        try store.deleteAll(scope: .session(sessionID))
        #expect(try store.environment(sessionID: sessionID, projectID: projectID)["SHARED"] == "project")
    }
}
