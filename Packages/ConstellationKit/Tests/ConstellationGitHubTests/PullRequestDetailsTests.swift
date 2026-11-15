import Foundation
import Testing
@testable import ConstellationGitHub

@Suite struct PullRequestDetailsTests {
    @Test func failingChecksComeFirstAndKnowTheirJob() {
        let checks = PullRequestDetails.parseChecks(#"""
        [{"bucket":"pass","link":"https://github.com/a/b/actions/runs/1/job/2","name":"lint","workflow":"CI"},
         {"bucket":"fail","link":"https://github.com/a/b/actions/runs/41/job/126","name":"test","workflow":"CI"},
         {"bucket":"pending","link":"https://ci.example.com/x","name":"deploy","workflow":""}]
        """#)
        #expect(checks.map(\.name) == ["test", "deploy", "lint"])
        #expect(checks.first?.job?.run == "41")
        #expect(checks.first?.job?.job == "126")
        #expect(checks[1].job == nil)
    }

    @Test func reviewsInlineAndPlainCommentsAllCount() {
        let comments = PullRequestDetails.parseComments(
            view: #"{"reviews":[{"author":{"login":"ana"},"body":"Please split this.","state":"CHANGES_REQUESTED"},{"author":{"login":"bo"},"body":"","state":"COMMENTED"}],"comments":[{"author":{"login":"cy"},"body":"Nice."}]}"#,
            inline: #"[{"user":{"login":"ana"},"body":"Round per line.","path":"Sources/Totals.swift","line":12,"html_url":"https://github.com/a/b/pull/1#discussion_r1"}]"#
        )
        #expect(comments.map(\.author) == ["ana", "ana", "cy"])
        #expect(comments[0].verdict == "CHANGES_REQUESTED")
        #expect(comments[1].path == "Sources/Totals.swift" && comments[1].line == 12)
    }

    @Test func aFailedLogKeepsOnlyItsText() {
        let log = "test\tRun tests\t\u{FEFF}2026-11-03T22:25:06.7849889Z --- FAIL: TestTotals\ntest\tRun tests\t2026-11-03T22:25:06.8Z \u{1B}[31mexpected 3, got 4\u{1B}[0m\n"
        #expect(PullRequestDetails.cleanLog(log, lines: 10) == "--- FAIL: TestTotals\nexpected 3, got 4")
        #expect(PullRequestDetails.cleanLog(log, lines: 1) == "expected 3, got 4")
    }
}
