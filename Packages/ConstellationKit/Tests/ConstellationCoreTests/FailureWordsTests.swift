import Testing
@testable import ConstellationCore

@Suite struct FailureWordsTests {
    @Test func knownErrorsBecomePlainWords() {
        #expect(FailureWords.summary("Claude Code exited with code 1", reason: .processExited) == "The agent stopped unexpectedly.")
        #expect(FailureWords.summary("Error: connect ECONNREFUSED 127.0.0.1:443", reason: .turnError) == "Couldn't reach the network.")
        #expect(FailureWords.summary("API Error: 429 {\"type\":\"rate_limit_error\"}", reason: .turnError) == "Rate limited. Try again in a moment.")
        #expect(FailureWords.summary("ENOENT: no such file or directory, open '/x/y'", reason: .turnError) == "A file or folder it needed is missing.")
    }

    @Test func anUnknownRawErrorIsntShownAsIs() {
        #expect(FailureWords.summary("TypeError: Cannot read properties of undefined", reason: .turnError) == "Something went wrong.")
        #expect(FailureWords.summary("Error Domain=NSCocoaErrorDomain Code=4", reason: .launch(.worktree)) == "Couldn't create the worktree.")
    }

    @Test func wordsAlreadyPlainAreKept() {
        #expect(FailureWords.summary("Constellation quit during launch", reason: .launch(.starting)) == "Constellation quit during launch")
        #expect(FailureWords.summary("The tests still fail on CI", reason: .reportedFailure) == "The tests still fail on CI")
    }

    @Test func theReasonSpeaksWhenThereIsNoMessage() {
        #expect(FailureWords.summary(nil, reason: .auth) == "Signed out. Sign in again to carry on.")
        #expect(FailureWords.summary(nil, reason: .launch(.setup)) == "The setup script failed.")
        #expect(FailureWords.summary(nil, reason: .turnError) == "Failed.")
    }

    @Test func aFailedResumeAndAFoundationErrorReadAsWords() {
        let raw = "Couldn't resume: The operation couldn’t be completed. (ConstellationProviders.CodexRPCError error 1.)"
        #expect(FailureWords.summary(raw, reason: .processExited) == "Couldn't pick the session back up. Retry to start it again.")
        #expect(FailureWords.summary("The operation couldn’t be completed. (Foo.BarError error 2.)", reason: .turnError) == "Something went wrong.")
    }
}
